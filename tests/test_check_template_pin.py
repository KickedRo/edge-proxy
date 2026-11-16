"""Tests for scripts/check_template_pin.py (no network: GitHub's responses come from fixture files).

Run: python -m unittest -v tests/test_check_template_pin.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "check_template_pin.py")
PIN = "bff2cddfece8e4f2c6d00b62ba45b8214c4727c5"
NOW = "2026-11-16T05:47:00Z"


def sha(n):
    return f"{n:040x}"


def entry(n, date):
    """A commit as the GitHub API lists it (only the fields the script reads, plus a message it must not print)."""
    return {"sha": sha(n), "commit": {"committer": {"date": date}, "message": "SECRET-MESSAGE"}}


def compare(commits, status="ahead", total=None):
    return {"status": status, "total_commits": len(commits) if total is None else total, "commits": commits}


def run(files, pin=PIN, extra=()):
    """Runs the script with fixture files {name: content}; returns the CompletedProcess."""
    with tempfile.TemporaryDirectory() as d:
        for name, content in files.items():
            with open(os.path.join(d, name + ".json"), "w") as f:
                f.write(content if isinstance(content, str) else json.dumps(content))
        pins = os.path.join(d, "pins.env")
        with open(pins, "w") as f:
            f.write(f"NGINX_PROXY_REF={pin}\nCRS_MAJOR=4\n")
        return subprocess.run([sys.executable, SCRIPT, "--pins", pins, "--fixtures", d, "--now", NOW, *extra],
                              capture_output=True, text=True)


WATCHED = ("nginx.tmpl", "app", "Dockerfile.dockergen", "network_internal.conf", "Dockerfile.debian")


def no_path_changes(**paths):
    """Fixture pages for the watched paths: empty unless given (keyword: the path with . as __, e.g. nginx__tmpl)."""
    files = {f"commits-{p}-1": [] for p in WATCHED}
    files.update({f"commits-{k.replace('__', '.')}-1": v for k, v in paths.items()})
    assert all(k[len("commits-"):-2] in WATCHED for k in files), files
    return files


class CheckTemplatePin(unittest.TestCase):
    def test_identical_is_current(self):
        r = run({"compare-1": compare([], status="identical")})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("OK: 0 commits", r.stdout)

    def test_commits_elsewhere_are_current(self):
        files = no_path_changes()
        files["compare-1"] = compare([entry(1, "2026-10-01T00:00:00Z"), entry(2, "2026-10-02T00:00:00Z")])
        r = run(files)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("OK: 2 commits", r.stdout)

    def test_template_change_older_than_a_week_is_behind(self):
        files = no_path_changes(nginx__tmpl=[entry(2, "2026-11-08T05:46:59Z")], app=[entry(3, "2026-11-15T00:00:00Z")])
        files["compare-1"] = compare([entry(1, "2026-11-01T00:00:00Z"), entry(2, "2026-11-08T05:46:59Z"),
                                      entry(3, "2026-11-15T00:00:00Z")])
        r = run(files)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(f"CHANGED {sha(2)[:12]} 2026-11-08T05:46:59Z nginx.tmpl", r.stdout)
        self.assertIn(f"CHANGED {sha(3)[:12]} 2026-11-15T00:00:00Z app", r.stdout)
        self.assertIn("BEHIND: 2 commits", r.stdout)
        self.assertNotIn("SECRET-MESSAGE", r.stdout + r.stderr)

    def test_change_of_exactly_a_week_is_still_recent(self):
        files = no_path_changes(Dockerfile__dockergen=[entry(2, "2026-11-09T05:47:00Z")])
        files["compare-1"] = compare([entry(2, "2026-11-09T05:47:00Z")])
        r = run(files)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("RECENT: 1 commits", r.stdout)
        self.assertIn("Dockerfile.dockergen", r.stdout)

    def test_edge_files_are_watched(self):
        # edge takes network_internal.conf and Dockerfile.debian's nginx.conf changes from the pinned commit too.
        files = no_path_changes(network_internal__conf=[entry(2, "2026-10-01T00:00:00Z")],
                                Dockerfile__debian=[entry(3, "2026-10-02T00:00:00Z")])
        files["compare-1"] = compare([entry(2, "2026-10-01T00:00:00Z"), entry(3, "2026-10-02T00:00:00Z")])
        r = run(files)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(f"CHANGED {sha(2)[:12]} 2026-10-01T00:00:00Z network_internal.conf", r.stdout)
        self.assertIn(f"CHANGED {sha(3)[:12]} 2026-10-02T00:00:00Z Dockerfile.debian", r.stdout)

    def test_grace_days_option(self):
        files = no_path_changes(app=[entry(2, "2026-11-14T00:00:00Z")])
        files["compare-1"] = compare([entry(2, "2026-11-14T00:00:00Z")])
        self.assertEqual(run(files).returncode, 0)
        self.assertEqual(run(files, extra=("--grace-days", "1")).returncode, 1)

    def test_one_commit_touching_two_paths_is_listed_once(self):
        files = no_path_changes(nginx__tmpl=[entry(2, "2026-10-01T00:00:00Z")], app=[entry(2, "2026-10-01T00:00:00Z")])
        files["compare-1"] = compare([entry(2, "2026-10-01T00:00:00Z")])
        r = run(files)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(f"CHANGED {sha(2)[:12]} 2026-10-01T00:00:00Z nginx.tmpl app", r.stdout)
        self.assertIn("BEHIND: 1 commits", r.stdout)

    def test_template_commits_the_pin_has_are_ignored(self):
        # The path listing reaches back before the pin (commit 9 is the pinned history, not on the comparison).
        files = no_path_changes(nginx__tmpl=[entry(9, "2026-09-01T00:00:00Z")])
        files["compare-1"] = compare([entry(1, "2026-10-01T00:00:00Z")])
        r = run(files)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_pages_are_followed(self):
        # 150 commits since the pin over two compare pages; the template change is on the second page of both lists.
        ahead = [entry(n, "2026-10-01T00:00:00Z") for n in range(1, 151)]
        tmpl = [entry(n, "2026-10-01T00:00:00Z") for n in range(1000, 1100)] + [entry(150, "2026-10-01T00:00:00Z")]
        files = no_path_changes()
        files.update({"compare-1": compare(ahead[:100], total=150), "compare-2": compare(ahead[100:], total=150),
                      "commits-nginx.tmpl-1": tmpl[:100], "commits-nginx.tmpl-2": tmpl[100:]})
        r = run(files)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(f"CHANGED {sha(150)[:12]}", r.stdout)

    def test_incomplete_or_unusable_answers_are_errors(self):
        good = no_path_changes(nginx__tmpl=[entry(2, "2026-10-01T00:00:00Z")])
        good["compare-1"] = compare([entry(2, "2026-10-01T00:00:00Z")])
        self.assertEqual(run(good).returncode, 1)
        cases = {
            "fewer commits than total": {"compare-1": compare([entry(2, "2026-10-01T00:00:00Z")], total=3)},
            "missing page": {"compare-1": compare([entry(n, "2026-10-01T00:00:00Z") for n in range(100)], total=101)},
            "not json": {"compare-1": "not json"},
            "no status": {"compare-1": {"total_commits": 0, "commits": []}},
            "short sha": {"compare-1": compare([{"sha": "abc", "commit": {"committer": {"date": NOW}}}])},
            "no date": {"compare-1": compare([{"sha": sha(2), "commit": {}}])},
            "bad date": {"compare-1": compare([entry(2, "2026-10-01 00:00:00")])},
            "path listing not a list": {"commits-nginx.tmpl-1": {"message": "API rate limit exceeded"}},
            "path listing missing": {"commits-app-1": None},
        }
        for name, change in cases.items():
            with self.subTest(name):
                files = dict(good)
                for k, v in change.items():
                    if v is None:
                        files.pop(k)
                    else:
                        files[k] = v
                r = run(files)
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertEqual(r.stdout, "")

    def test_bad_arguments_are_errors(self):
        files = {"compare-1": compare([], status="identical")}
        self.assertEqual(run(files, pin="bff2cddfece8").returncode, 2)
        self.assertEqual(run(files, extra=("--grace-days", "seven")).returncode, 2)
        self.assertEqual(run(files, extra=("--now", "yesterday")).returncode, 2)


if __name__ == "__main__":
    unittest.main()
