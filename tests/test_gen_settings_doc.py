"""Tests for scripts/gen_settings_doc.py.

Run: python -m unittest -v tests/test_gen_settings_doc.py
"""
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "gen_settings_doc.py")

# VARIABLE DEFAULT ALLOWED WEAKER_IF RISK_TEXT DESCRIPTION WHEN
ROWS = [
    ("ALPHA_MODE", "on", "on|off", "off", "Alpha protection is lost.", "Turns alpha on.", "When alpha breaks a client."),
    ("BETA_LIMIT", "5", "<integer>", ">5", "More beta gets through.", "Limits beta.", "For sites with much beta."),
    ("GAMMA_STATUS", "403", "403|406", "-", "No security effect.", "Status for gamma.", "To match a client."),
]
FIXTURE = "# A comment line, then an empty line.\n\n" + "".join("\t".join(r) + "\n" for r in ROWS)


def run(tsv_text):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "settings.tsv")
        with open(path, "w") as f:
            f.write(tsv_text)
        return subprocess.run([sys.executable, SCRIPT, path], capture_output=True, text=True)


def table_rows(markdown):
    """Body rows of the settings table (lines starting with '|', minus the header and separator)."""
    lines = [line for line in markdown.splitlines() if line.startswith("|")]
    return lines[2:]


class GenSettingsDoc(unittest.TestCase):
    def test_every_row_rendered(self):
        r = run(FIXTURE)
        self.assertEqual(r.returncode, 0, r.stderr)
        body = table_rows(r.stdout)
        self.assertEqual(len(body), len(ROWS), r.stdout)
        for (var, default, _allowed, _weaker, risk, what, when), line in zip(ROWS, body):
            for text in (var, default, risk, what, when):
                self.assertIn(text, line)
        # The weakening rule and the allowed values are shown too.
        self.assertIn("`off`", body[0])
        self.assertIn("above `5`", body[1])
        self.assertIn("`406`", body[2])

    def test_missing_risk_text_fails(self):
        r = run(FIXTURE.replace("More beta gets through.", ""))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertIn("BETA_LIMIT", r.stderr)

    def test_committed_doc_is_current(self):
        r = subprocess.run([sys.executable, SCRIPT, os.path.join(ROOT, "edge", "settings.tsv")],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(ROOT, "docs", "settings.md")) as f:
            self.assertEqual(r.stdout, f.read(),
                             "docs/settings.md is stale: scripts/gen_settings_doc.py edge/settings.tsv > docs/settings.md")


if __name__ == "__main__":
    unittest.main()
