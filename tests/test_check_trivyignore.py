import os, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "check_trivyignore.py")
TODAY = "2026-11-12"


def check(text, today=TODAY):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, ".trivyignore.yaml")
        with open(path, "w") as f:
            f.write(text)
        return subprocess.run([sys.executable, SCRIPT, path, "--today", today],
                              capture_output=True, text=True)


def entry(statement='statement: "no fix upstream, not reachable"', expired="expired_at: 2026-12-01"):
    lines = ["vulnerabilities:", "  - id: CVE-2099-0001", "    paths:", '      - "usr/bin/x"']
    lines += ["    " + x for x in (statement, expired) if x]
    return "\n".join(lines) + "\n"


class CheckTrivyIgnore(unittest.TestCase):
    def test_valid_entry_passes(self):
        r = check(entry())
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_empty_list_passes(self):
        r = check("# header\nvulnerabilities: []\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_missing_statement_fails(self):
        r = check(entry(statement=""))
        self.assertEqual(r.returncode, 1)
        self.assertIn("statement", r.stderr)

    def test_missing_expired_at_fails(self):
        r = check(entry(expired=""))
        self.assertEqual(r.returncode, 1)
        self.assertIn("expired_at", r.stderr)

    def test_expired_fails(self):
        r = check(entry(expired="expired_at: 2026-11-11"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("expired", r.stderr)

    def test_today_is_not_expired_and_30_days_ahead_passes(self):
        self.assertEqual(check(entry(expired="expired_at: 2026-11-12")).returncode, 0)
        self.assertEqual(check(entry(expired="expired_at: 2026-12-12")).returncode, 0)

    def test_more_than_30_days_ahead_fails(self):
        r = check(entry(expired="expired_at: 2026-12-13"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("30 days", r.stderr)


if __name__ == "__main__":
    unittest.main()
