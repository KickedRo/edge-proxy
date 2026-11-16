#!/usr/bin/env python3
"""Freshness check of the published :latest images.

Usage: check_freshness.py --resolved VERSIONS_FILE --max-age-days N --last-build RUNS_JSON --max-build-age-days M
                          [--now ISO-8601] NAME=IMAGE_JSON...

IMAGE_JSON is the image configuration of a published :latest, as printed by
`docker buildx imagetools inspect REF --format '{{json .Image}}'`. VERSIONS_FILE is the output of
scripts/resolve_versions.py, run now. RUNS_JSON is the output of
`gh api 'repos/OWNER/REPO/actions/workflows/build.yml/runs?branch=main&event=schedule&status=completed&per_page=1'`.
Unhealthy (one line each): no completed scheduled build run; the newest one did not conclude with success; it was
last updated more than M days before now (the daily build must keep running: an unchanged image is not republished,
so the image age alone says nothing); an image created more than N days before now (backstop); an image whose
NGINX_VERSION in its org.kickedro.versions label is lower than the resolved one (compared as numbers, part by
part: 1.31.9 < 1.31.10).
Exit 0 if everything is healthy, 1 if anything is not, 2 on unusable input (unreadable file, no created date, no
org.kickedro.versions label, a version that is not dotted numbers, a run list that is not as above, a bad argument).
"""
import argparse
import datetime
import json
import re
import sys

VERSIONS_LABEL = "org.kickedro.versions"


class InputError(Exception):
    pass


def version(text, what):
    m = re.fullmatch(r"v?(\d+(?:\.\d+)*)", text or "")
    if not m:
        raise InputError(f"{what}: {text!r} is not a version (dotted numbers)")
    return tuple(int(x) for x in m.group(1).split("."))


def timestamp(text, what):
    """RFC 3339 as Go writes it: fractional seconds up to nanoseconds, Z or an offset."""
    m = re.fullmatch(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})", text or "")
    if not m:
        raise InputError(f"{what}: {text!r} is not an RFC 3339 timestamp")
    base, frac, zone = m.groups()
    micro = (frac or "").ljust(6, "0")[:6]
    return datetime.datetime.fromisoformat(f"{base}.{micro}{'+00:00' if zone == 'Z' else zone}")


def read_versions(path):
    try:
        with open(path) as f:
            pairs = dict(line.strip().split("=", 1) for line in f if "=" in line)
    except OSError as e:
        raise InputError(f"{path}: {e}")
    if "NGINX_VERSION" not in pairs:
        raise InputError(f"{path}: no NGINX_VERSION")
    return pairs


def read_image(path):
    try:
        with open(path) as f:
            config = json.load(f)
    except (OSError, ValueError) as e:
        raise InputError(f"{path}: {e}")
    if not isinstance(config, dict):
        raise InputError(f"{path}: not an image configuration")
    labels = (config.get("config") or {}).get("Labels") or {}
    if VERSIONS_LABEL not in labels:
        raise InputError(f"{path}: no {VERSIONS_LABEL} label")
    pairs = dict(p.split("=", 1) for p in labels[VERSIONS_LABEL].split(";") if "=" in p)
    if "NGINX_VERSION" not in pairs:
        raise InputError(f"{path}: {VERSIONS_LABEL} has no NGINX_VERSION")
    return timestamp(config.get("created"), f"{path}: created"), pairs


def read_last_build(path):
    """The newest completed scheduled run: (conclusion, updated_at, url), or None when there is none."""
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise InputError(f"{path}: {e}")
    runs = data.get("workflow_runs") if isinstance(data, dict) else None
    if not isinstance(runs, list):
        raise InputError(f"{path}: no workflow_runs list")
    if not runs:
        return None
    run = runs[0]
    if not isinstance(run, dict) or not isinstance(run.get("conclusion"), str) \
            or not isinstance(run.get("html_url"), str):
        raise InputError(f"{path}: the run has no conclusion or html_url")
    return run["conclusion"], timestamp(run.get("updated_at"), f"{path}: updated_at"), run["html_url"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--resolved", required=True)
    ap.add_argument("--max-age-days", required=True)
    ap.add_argument("--last-build", required=True)
    ap.add_argument("--max-build-age-days", required=True)
    ap.add_argument("--now")
    ap.add_argument("images", nargs="*", metavar="NAME=IMAGE_JSON")
    args = ap.parse_args()
    try:
        if not re.fullmatch(r"\d+", args.max_age_days):
            raise InputError(f"--max-age-days: {args.max_age_days!r} is not a whole number of days")
        max_age = datetime.timedelta(days=int(args.max_age_days))
        if not re.fullmatch(r"\d+", args.max_build_age_days):
            raise InputError(f"--max-build-age-days: {args.max_build_age_days!r} is not a whole number of days")
        max_build_age = datetime.timedelta(days=int(args.max_build_age_days))
        now = timestamp(args.now, "--now") if args.now else datetime.datetime.now(datetime.timezone.utc)
        if not args.images:
            raise InputError("no image given")
        last_build = read_last_build(args.last_build)
        upstream_text = read_versions(args.resolved)["NGINX_VERSION"]
        upstream = version(upstream_text, f"{args.resolved}: NGINX_VERSION")
        checked = []
        for item in args.images:
            name, sep, path = item.partition("=")
            if not sep or not name or not path:
                raise InputError(f"{item!r}: expected NAME=IMAGE_JSON")
            created, pairs = read_image(path)
            checked.append((name, created, pairs["NGINX_VERSION"],
                            version(pairs["NGINX_VERSION"], f"{path}: NGINX_VERSION")))
    except InputError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    healthy = True
    if last_build is None:
        healthy = False
        print("BUILD: no completed scheduled build run of build.yml on main")
    else:
        conclusion, updated, url = last_build
        build_age = now - updated
        if conclusion != "success":
            healthy = False
            print(f"BUILD: the last scheduled build concluded with {conclusion}: {url}")
        elif build_age > max_build_age:
            healthy = False
            print(f"BUILD: the last successful scheduled build ran {updated.isoformat()}, older than "
                  f"{args.max_build_age_days} days ({build_age} old): {url}")
        else:
            print(f"OK build: the last scheduled build succeeded {updated.isoformat()}: {url}")
    for name, created, nginx_text, nginx in checked:
        age = now - created
        if age > max_age:
            healthy = False
            print(f"STALE {name}: created {created.isoformat()}, older than {args.max_age_days} days ({age} old)")
        if nginx < upstream:
            healthy = False
            print(f"BEHIND {name}: NGINX_VERSION {nginx_text} is lower than upstream {upstream_text}")
        if age <= max_age and nginx >= upstream:
            print(f"OK {name}: created {created.isoformat()}, NGINX_VERSION {nginx_text} (upstream {upstream_text})")
    return 0 if healthy else 1


if __name__ == "__main__":
    sys.exit(main())
