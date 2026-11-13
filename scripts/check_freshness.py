#!/usr/bin/env python3
"""Freshness check of the published :latest images.

Usage: check_freshness.py --resolved VERSIONS_FILE --max-age-days N [--now ISO-8601] NAME=IMAGE_JSON...

IMAGE_JSON is the image configuration of a published :latest, as printed by
`docker buildx imagetools inspect REF --format '{{json .Image}}'`. VERSIONS_FILE is the output of
scripts/resolve_versions.py, run now. An image is unhealthy when it was created more than N days before now, or
when the NGINX_VERSION in its org.kickedro.versions label is lower than the resolved one (compared as numbers,
part by part: 1.31.9 < 1.31.10). One line per image and problem on stdout.
Exit 0 if every image is healthy, 1 if any is not, 2 on unusable input (unreadable file, no created date, no
org.kickedro.versions label, a version that is not dotted numbers, a bad argument).
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--resolved", required=True)
    ap.add_argument("--max-age-days", required=True)
    ap.add_argument("--now")
    ap.add_argument("images", nargs="*", metavar="NAME=IMAGE_JSON")
    args = ap.parse_args()
    try:
        if not re.fullmatch(r"\d+", args.max_age_days):
            raise InputError(f"--max-age-days: {args.max_age_days!r} is not a whole number of days")
        max_age = datetime.timedelta(days=int(args.max_age_days))
        now = timestamp(args.now, "--now") if args.now else datetime.datetime.now(datetime.timezone.utc)
        if not args.images:
            raise InputError("no image given")
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
