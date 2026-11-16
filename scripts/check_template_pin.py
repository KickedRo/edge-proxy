#!/usr/bin/env python3
"""Alarm for nginx-proxy's template moving past the pinned commit.

Usage: check_template_pin.py [--pins PINS_ENV] [--grace-days N] [--now ISO-8601] [--fixtures DIR]

Compares NGINX_PROXY_REF in pins.env with nginx-proxy's main branch on GitHub. The pin is behind when main has
commits the pin does not have that touch nginx.tmpl, app/ or Dockerfile.dockergen (what the gen image takes from
nginx-proxy), and the oldest of them (by commit date) is more than N days old (default 7): upstream gets a week to
settle, and the images stay within about a week of it. Moving the pin stays a manual, reviewed change
(docs/maintenance.md).

Prints one line per such commit (short SHA, commit date, paths) and a verdict on stdout; no commit messages.
Exit 0 when the pin is current or the changes are younger than N days, 1 when the pin is behind, 2 on a lookup failure
or unusable input (never a verdict from incomplete data).

--fixtures DIR reads the GitHub responses from files instead (tests): compare-<page>.json for the comparison and
commits-<path>-<page>.json for the commits that touch each path, pages counted from 1.
"""
import argparse
import datetime
import os
import re
import sys

from resolve_versions import ROOT, LookupError_, fetch_json, read_pins

REPO = "nginx-proxy/nginx-proxy"
BRANCH = "main"
PATHS = ("nginx.tmpl", "app", "Dockerfile.dockergen")
PER_PAGE = 100
MAX_PAGES = 10  # per listing; more is a failure, never a silent cut
SHA = re.compile(r"[0-9a-f]{40}")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")


def timestamp(text, what):
    """A UTC timestamp as GitHub writes them (2026-11-16T05:47:00Z)."""
    if not isinstance(text, str) or not DATE.fullmatch(text):
        raise ValueError(f"{what}: {text!r} is not a timestamp like 2026-11-16T05:47:00Z")
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


def commit(entry, what):
    """(sha, commit date) of a commit in a GitHub API listing."""
    if not isinstance(entry, dict) or not isinstance(entry.get("sha"), str) or not SHA.fullmatch(entry["sha"]):
        raise ValueError(f"{what}: a commit without a full SHA")
    try:
        date = entry["commit"]["committer"]["date"]
    except (KeyError, TypeError):
        raise ValueError(f"{what}: commit {entry['sha'][:12]} has no commit date")
    return entry["sha"], timestamp(date, f"{what}: commit {entry['sha'][:12]}")


class GitHub:
    """Pages of GitHub API listings, from the API or from fixture files."""

    def __init__(self, fixtures):
        self.fixtures = fixtures

    def page(self, name, url, number):
        if self.fixtures:
            return fetch_json(None, os.path.join(self.fixtures, f"{name}-{number}.json"))
        return fetch_json(f"{url}{'&' if '?' in url else '?'}per_page={PER_PAGE}&page={number}")


def ahead_commits(github, pin):
    """{sha: commit date} of every commit on BRANCH that the pin does not have."""
    url = f"https://api.github.com/repos/{REPO}/compare/{pin}...{BRANCH}"
    found = {}
    total = None
    for number in range(1, MAX_PAGES + 1):
        data = github.page("compare", url, number)
        if not isinstance(data, dict) or data.get("status") not in ("identical", "ahead", "behind", "diverged"):
            raise ValueError(f"compare page {number}: not a comparison")
        if not isinstance(data.get("total_commits"), int) or not isinstance(data.get("commits"), list):
            raise ValueError(f"compare page {number}: no total_commits or commits list")
        if total is None:
            total = data["total_commits"]
        elif data["total_commits"] != total:
            raise ValueError("the comparison changed while it was read")
        for entry in data["commits"]:
            sha, date = commit(entry, f"compare page {number}")
            found[sha] = date
        if len(found) >= total:
            return found
        if len(data["commits"]) < PER_PAGE:
            raise ValueError(f"the comparison lists {len(found)} of its {total} commits")
    raise LookupError_(f"more than {MAX_PAGES} pages of commits since the pin")


def path_commits(github, path, since):
    """[(sha, commit date)] of the commits on BRANCH that touch path, with a commit date from since on."""
    url = f"https://api.github.com/repos/{REPO}/commits?sha={BRANCH}&path={path}&since={since}"
    found = []
    for number in range(1, MAX_PAGES + 1):
        data = github.page(f"commits-{path}", url, number)
        if not isinstance(data, list):
            raise ValueError(f"commits touching {path}, page {number}: not a list")
        found += [commit(entry, f"commits touching {path}, page {number}") for entry in data]
        if len(data) < PER_PAGE:
            return found
    raise LookupError_(f"more than {MAX_PAGES} pages of commits touching {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pins", default=os.path.join(ROOT, "pins.env"))
    ap.add_argument("--grace-days", default="7")
    ap.add_argument("--now")
    ap.add_argument("--fixtures")
    args = ap.parse_args()
    try:
        if not re.fullmatch(r"\d{1,3}", args.grace_days):
            raise ValueError(f"--grace-days: {args.grace_days!r} is not a whole number of days")
        grace = datetime.timedelta(days=int(args.grace_days))
        now = timestamp(args.now, "--now") if args.now else datetime.datetime.now(datetime.timezone.utc)
        pin = read_pins(args.pins).get("NGINX_PROXY_REF", "")
        if not SHA.fullmatch(pin):
            raise ValueError(f"{args.pins}: NGINX_PROXY_REF is not a full commit SHA")
        github = GitHub(args.fixtures)
        ahead = ahead_commits(github, pin)
        changed = {}  # sha -> (commit date, [paths])
        if ahead:
            since = min(ahead.values()).strftime("%Y-%m-%dT%H:%M:%SZ")
            for path in PATHS:
                for sha, date in path_commits(github, path, since):
                    if sha in ahead:
                        changed.setdefault(sha, (date, []))[1].append(path)
    except (LookupError_, ValueError, OSError) as e:
        print(f"check_template_pin: {e}", file=sys.stderr)
        return 2

    where = f"nginx-proxy's {BRANCH} since the pin {pin[:12]}"
    if not changed:
        print(f"OK: {len(ahead)} commits on {where}, none touches {', '.join(PATHS)}")
        return 0
    for sha, (date, paths) in sorted(changed.items(), key=lambda item: item[1][0]):
        print(f"CHANGED {sha[:12]} {date:%Y-%m-%dT%H:%M:%SZ} {' '.join(paths)}")
    age = now - min(date for date, _ in changed.values())
    if age > grace:
        print(f"BEHIND: {len(changed)} commits on {where} touch the template; the oldest is {age.days} days old, more "
              f"than {args.grace_days}. Review them and move NGINX_PROXY_REF (docs/maintenance.md).")
        return 1
    print(f"RECENT: {len(changed)} commits on {where} touch the template; the oldest is not older than "
          f"{args.grace_days} days yet.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
