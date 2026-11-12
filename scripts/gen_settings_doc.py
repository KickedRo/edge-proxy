#!/usr/bin/env python3
"""Render the settings table of the edge image from its settings file.

Usage: scripts/gen_settings_doc.py edge/settings.tsv > docs/settings.md

The TSV format (seven TAB-separated fields per setting, none empty) is described at the top of edge/settings.tsv.
Exit 0 with the Markdown on stdout; exit 1 with a message on stderr, and nothing on stdout, if the file cannot be
read or a line is malformed.
"""
import re
import sys

FIELDS = ("VARIABLE", "DEFAULT", "ALLOWED", "WEAKER_IF", "RISK_TEXT", "DESCRIPTION", "WHEN")
VARIABLE = re.compile(r"[A-Z][A-Z0-9_]*\Z")

HEADER = """\
<!-- Generated from edge/settings.tsv by scripts/gen_settings_doc.py: edit the TSV, then regenerate this file. -->
# Settings

Every setting of the `edge` image is one environment variable with a secure default; an empty variable counts as
unset. At start the container checks every value. A value that is not allowed stops it, with a message naming the
variable and the allowed values. A value that is weaker than the default prints one line starting with `SECURITY:`,
saying what protection is lost and linking here.

Value forms: `<integer>` a whole number from 1; `<time>` a whole number with the unit `ms`, `s`, `m` or `h`
(`10s`); `<buffers>` a count and a size separated by a space (`4 8k`; the size in bytes or with `k` or `m`);
`<path>` an absolute file path (letters, digits and `. _ / -`). "Weaker" lists the values that print the
`SECURITY:` line: "above" compares numbers by value, times by duration, and buffers by count or size.

| Variable | Default | What it does | If you weaken it | When you might |
|---|---|---|---|---|
"""


class SettingsError(Exception):
    pass


def parse(path):
    """The settings as a list of dicts keyed by FIELDS, in file order."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError as e:
        raise SettingsError(f"{path}: {e}")
    rows = []
    for number, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        values = line.split("\t")
        where = f"{path}:{number}"
        if len(values) != len(FIELDS):
            raise SettingsError(f"{where}: {len(values)} fields, expected {len(FIELDS)} ({values[0]})")
        row = dict(zip(FIELDS, values))
        if not VARIABLE.match(row["VARIABLE"]):
            raise SettingsError(f"{where}: bad variable name {row['VARIABLE']!r}")
        for field in FIELDS:
            if not row[field].strip():
                raise SettingsError(f"{where}: {row['VARIABLE']} has an empty {field}")
        rows.append(row)
    if not rows:
        raise SettingsError(f"{path}: no settings")
    return rows


def cell(text):
    """Text for a table cell (a | would end the cell)."""
    return text.replace("|", "\\|")


def code(text):
    return cell(f"`{text}`")


def render(rows):
    out = [HEADER]
    for r in rows:
        var = r["VARIABLE"]
        allowed = ", ".join(code(a) for a in r["ALLOWED"].split("|"))
        weaker = r["WEAKER_IF"]
        if weaker == "-":
            risk = cell(r["RISK_TEXT"])
        elif weaker.startswith(">"):
            risk = f"Weaker: above {code(weaker[1:])}. {cell(r['RISK_TEXT'])}"
        else:
            risk = f"Weaker: {', '.join(code(w) for w in weaker.split('|'))}. {cell(r['RISK_TEXT'])}"
        out.append(f'| <a id="{var.lower()}"></a>{code(var)} | {code(r["DEFAULT"])} '
                   f'| {cell(r["DESCRIPTION"])} Allowed: {allowed}. | {risk} | {cell(r["WHEN"])} |\n')
    return "".join(out)


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} SETTINGS_TSV", file=sys.stderr)
        return 1
    try:
        markdown = render(parse(argv[1]))
    except SettingsError as e:
        print(f"gen_settings_doc: {e}", file=sys.stderr)
        return 1
    sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
