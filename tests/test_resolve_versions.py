import os, shutil, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "resolve_versions.py")
FIX = os.path.join(ROOT, "tests", "fixtures")


def run(fixtures, out):
    return subprocess.run(
        [sys.executable, SCRIPT, "--fixtures", fixtures, "--out", out],
        capture_output=True, text=True)


def parse(path):
    with open(path) as f:
        return dict(line.rstrip("\n").split("=", 1) for line in f if line.strip())


class ResolveVersions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.out = os.path.join(self.tmp, "versions.env")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_picks_highest_mainline_nginx(self):
        r = run(FIX, self.out)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(parse(self.out)["NGINX_VERSION"], "1.31.10")

    def test_ignores_prerelease_and_other_major(self):
        run(FIX, self.out)
        v = parse(self.out)
        self.assertEqual(v["CRS_VERSION"], "v4.30.0")
        self.assertEqual(v["MODSECURITY_VERSION"], "v3.0.17")
        self.assertEqual(v["MODSECURITY_NGINX_VERSION"], "v1.0.4")
        self.assertEqual(v["DOCKER_GEN_VERSION"], "0.17.2")

    def test_nginx_proxy_ref_from_pins(self):
        run(FIX, self.out)
        want = parse(os.path.join(ROOT, "pins.env"))["NGINX_PROXY_REF"]
        self.assertEqual(parse(self.out)["NGINX_PROXY_REF"], want)

    def test_output_is_plain_key_value(self):
        run(FIX, self.out)
        with open(self.out) as f:
            lines = f.read().splitlines()
        self.assertEqual(len(lines), 6)
        for line in lines:
            k, _, val = line.partition("=")
            self.assertRegex(k, r"^[A-Z_]+$")
            self.assertNotRegex(val, r"[\"'# ]")

    def test_lookup_failure_exits_2_without_output(self):
        d = os.path.join(self.tmp, "fx")
        shutil.copytree(FIX, d)
        os.remove(os.path.join(d, "github_coreruleset_coreruleset.json"))
        r = run(d, self.out)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.exists(self.out))


if __name__ == "__main__":
    unittest.main()
