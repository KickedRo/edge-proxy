#!/usr/bin/env python3
"""Check a Trivy ignore file (.trivyignore.yaml): every exception must carry a reason and an expiry.

Usage: check_trivyignore.py FILE [--today YYYY-MM-DD]
Exit 0 if all entries are fine, 1 if any entry has no `statement`, no `expired_at`, an `expired_at` in the
past or today (Trivy stops applying an entry at 00:00 UTC on that date), or an `expired_at` more than 30 days after today.
Exit 2 if the file cannot be parsed.

Parsing choice: stdlib only, so a minimal reader for the Trivy ignore format (not the JSON-compatible subset).
It understands exactly what the format needs: the top-level keys (vulnerabilities, misconfigurations, secrets,
licenses), each either `[]` or a list of entries `- key: value` with scalar values (plain or quoted, optionally
followed by a comment) and `paths`/`purls` lists (dashes indented or not), plus comments. An empty value, `~`,
`null` or a comment-only value counts as missing. Anything else (anchors, flow mappings, multi-line scalars) is
rejected rather than guessed at.
"""
import argparse
import datetime
import re
import sys

SECTIONS = ("vulnerabilities", "misconfigurations", "secrets", "licenses")
MAX_DAYS = 30


class ParseError(Exception):
    pass


NULLS = ("~", "null", "Null", "NULL")


def scalar(text):
    """A plain or quoted scalar; YAML null, an empty value or a comment-only value gives ''."""
    text = text.strip()
    m = re.fullmatch(r"(['\"])(.*)\1\s*(?:#.*)?", text)
    if m:
        return m.group(2)
    if text[:1] in "|>&*{[!":
        raise ParseError("unsupported YAML value: " + text)
    text = re.sub(r"(^|\s+)#.*$", "", text).strip()
    return "" if text in NULLS else text


def parse(text):
    """Return {section: [entry dict, ...]}."""
    data, section, entry, listkey, item_indent = {}, None, None, None, 0
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        body = line.strip()
        where = "line %d: " % n
        if indent == 0 and not (section and body.startswith("- ")):
            m = re.fullmatch(r"(\w+):\s*(\[\])?\s*(#.*)?", body)
            if not m or m.group(1) not in SECTIONS:
                raise ParseError(where + "expected one of %s at top level" % ", ".join(SECTIONS))
            section, entry, listkey = m.group(1), None, None
            data[section] = []
        elif section is None:
            raise ParseError(where + "content before a section")
        elif body.startswith("- ") and listkey and indent >= item_indent + 2:
            # a list item of the entry's current list (also when the dash is not indented under its key)
            entry[listkey].append(scalar(body[2:]))
        elif body.startswith("- "):
            entry, item_indent = {}, indent
            data[section].append(entry)
            body = body[2:]
            _set(entry, body, where)
            listkey = _listkey(entry, body)
        elif entry is not None:
            _set(entry, body, where)
            listkey = _listkey(entry, body)
        else:
            raise ParseError(where + "unexpected content")
    return data


def _set(entry, body, where):
    m = re.fullmatch(r"(\w+):(?:\s+(.*))?", body)
    if not m:
        raise ParseError(where + "expected `key: value`")
    key, val = m.group(1), m.group(2)
    entry[key] = [] if val is None or val == "" else scalar(val)


def _listkey(entry, body):
    key = body.split(":", 1)[0]
    return key if entry[key] == [] else None


def problems(data, today):
    out = []
    for section, entries in data.items():
        for i, e in enumerate(entries, 1):
            name = "%s #%d (%s)" % (section, i, e.get("id", "no id"))
            if not e.get("statement"):
                out.append("%s: missing statement" % name)
            raw = e.get("expired_at")
            if not raw:
                out.append("%s: missing expired_at" % name)
                continue
            try:
                exp = datetime.date.fromisoformat(raw)
            except ValueError:
                out.append("%s: expired_at is not YYYY-MM-DD: %s" % (name, raw))
                continue
            if exp <= today:
                out.append("%s: expired on %s (an entry stops applying at 00:00 UTC on its expired_at date)" % (name, raw))
            elif exp > today + datetime.timedelta(days=MAX_DAYS):
                out.append("%s: expired_at %s is more than %d days ahead of %s" % (name, raw, MAX_DAYS, today))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--today", default=None, help="YYYY-MM-DD (default: today, UTC)")
    a = ap.parse_args()
    today = datetime.date.fromisoformat(a.today) if a.today else datetime.datetime.now(datetime.timezone.utc).date()
    try:
        with open(a.file) as f:
            data = parse(f.read())
    except (OSError, ParseError) as e:
        print("check_trivyignore: %s" % e, file=sys.stderr)
        return 2
    bad = problems(data, today)
    for b in bad:
        print("check_trivyignore: " + b, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
