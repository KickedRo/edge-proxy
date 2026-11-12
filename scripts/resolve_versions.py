#!/usr/bin/env python3
"""Resolve the latest upstream versions within the majors pinned in pins.env.

Writes KEY=VALUE lines (usable as docker --build-arg values). Exit 0 on
success; exit 2 on any lookup failure, in which case no output is written.
"""
import argparse
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_PAGES = 10  # per minor line; hitting it is a failure, never a silent cut
MAX_MINOR = 99

GITHUB = [
    # (output key, owner/repo, pins.env major key)
    ("MODSECURITY_VERSION", "owasp-modsecurity/ModSecurity", "MODSECURITY_MAJOR"),
    ("MODSECURITY_NGINX_VERSION", "owasp-modsecurity/ModSecurity-nginx", "MODSECURITY_NGINX_MAJOR"),
    ("CRS_VERSION", "coreruleset/coreruleset", "CRS_MAJOR"),
    ("DOCKER_GEN_VERSION", "nginx-proxy/docker-gen", "DOCKER_GEN_MAJOR"),
]


class LookupError_(Exception):
    pass


def read_pins(path):
    pins = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                pins[k] = v
    return pins


def fetch_json(url, fixture_path=None):
    if fixture_path is not None:
        try:
            with open(fixture_path) as f:
                return json.load(f)
        except (OSError, ValueError) as e:
            raise LookupError_(f"fixture {fixture_path}: {e}")
    headers = {"Accept": "application/json", "User-Agent": "edge-proxy-resolver"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
            return json.load(r)
    except Exception as e:
        raise LookupError_(f"{url}: {e}")


def parse_version(s):
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", s)
    return tuple(int(x) for x in m.groups()) if m else None


def tag_names(data):
    if not isinstance(data, dict) or not isinstance(data.get("results"), list):
        raise LookupError_("Docker Hub response has no results list")
    names = []
    for t in data["results"]:
        if not isinstance(t, dict) or not isinstance(t.get("name"), str):
            raise LookupError_("Docker Hub result without a tag name")
        names.append(t["name"])
    return names


def mainline(names, major, minor=None):
    best = None
    for n in names:
        v = parse_version(n)
        if v and v[0] == major and v[1] % 2 == 1 and (minor is None or v[1] == minor):
            if best is None or v > best:
                best = v
    return best


def nginx_version(major, fixtures):
    major = int(major)
    if fixtures:
        data = fetch_json(None, os.path.join(fixtures, "dockerhub_nginx.json"))
        names = tag_names(data)
        if data.get("next"):
            raise LookupError_("Docker Hub tag list incomplete (more pages)")
        best = mainline(names, major)
    else:
        # Walk odd minors from newest downward; each query is small and is read
        # completely, so a lower version is never returned by truncation.
        best = None
        for minor in range(MAX_MINOR, 0, -2):
            url = ("https://hub.docker.com/v2/repositories/library/nginx/tags"
                   f"?page_size=100&name={major}.{minor}.")
            names = []
            for _ in range(MAX_PAGES):
                data = fetch_json(url)
                names += tag_names(data)
                url = data.get("next")
                if not url:
                    break
            else:
                raise LookupError_(f"more than {MAX_PAGES} pages for nginx {major}.{minor}.")
            best = mainline(names, major, minor)
            if best:
                break
    if best is None:
        raise LookupError_("no nginx mainline tag found")
    return ".".join(map(str, best))


def github_version(repo, major, fixtures):
    fp = os.path.join(fixtures, "github_" + repo.replace("/", "_") + ".json") if fixtures else None
    data = fetch_json(f"https://api.github.com/repos/{repo}/releases?per_page=100", fp)
    if not isinstance(data, list):
        raise LookupError_(f"{repo}: releases response is not a list")
    best = None
    for rel in data:
        if not isinstance(rel, dict):
            raise LookupError_(f"{repo}: malformed release entry")
        if rel.get("draft") or rel.get("prerelease"):
            continue
        tag = rel.get("tag_name")
        if not isinstance(tag, str):
            raise LookupError_(f"{repo}: release without tag_name")
        v = parse_version(tag)
        if v and v[0] == int(major) and (best is None or v > best[0]):
            best = (v, tag)
    if best is None:
        raise LookupError_(f"no release for {repo} in major {major}")
    return best[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures")
    ap.add_argument("--out")
    ap.add_argument("--pins", default=os.path.join(ROOT, "pins.env"))
    a = ap.parse_args()
    try:
        pins = read_pins(a.pins)
        res = [("NGINX_VERSION", nginx_version(pins["NGINX_MAJOR"], a.fixtures))]
        for key, repo, mk in GITHUB:
            res.append((key, github_version(repo, pins[mk], a.fixtures)))
        res.append(("NGINX_PROXY_REF", pins["NGINX_PROXY_REF"]))
    except (LookupError_, KeyError, ValueError, TypeError, AttributeError, OSError) as e:
        print(f"resolve_versions: lookup failed: {e}", file=sys.stderr)
        return 2
    text = "".join(f"{k}={v}\n" for k, v in res)
    if a.out:
        with open(a.out, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
