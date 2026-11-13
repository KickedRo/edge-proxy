import json, os, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "check_freshness.py")
NOW = "2026-11-13T05:47:00Z"
VERSIONS = ("NGINX_VERSION=1.31.10\nMODSECURITY_VERSION=v3.0.17\nCRS_VERSION=v4.30.0\n"
            "DOCKER_GEN_VERSION=0.17.2\nNGINX_PROXY_REF=bff2cddfece8e4f2c6d00b62ba45b8214c4727c5\n")


def image(created="2026-11-12T03:30:00.123456789Z", nginx="1.31.10", labels=None):
    """An OCI image config as `docker buildx imagetools inspect REF --format '{{json .Image}}'` prints it."""
    if labels is None:
        labels = {"org.kickedro.versions": f"NGINX_VERSION={nginx};CRS_VERSION=v4.30.0;DOCKER_GEN_VERSION=0.17.2",
                  "org.kickedro.build-key": "sha256:" + "0" * 64}
    config = {"architecture": "amd64", "os": "linux", "config": {"Labels": labels}}
    if created is not None:
        config["created"] = created
    return config


def check(images, max_age="8", versions=VERSIONS, now=NOW):
    with tempfile.TemporaryDirectory() as d:
        resolved = os.path.join(d, "versions.env")
        with open(resolved, "w") as f:
            f.write(versions)
        args = [sys.executable, SCRIPT, "--resolved", resolved, "--max-age-days", max_age, "--now", now]
        for name, content in images.items():
            path = os.path.join(d, name + ".json")
            with open(path, "w") as f:
                f.write(content if isinstance(content, str) else json.dumps(content))
            args.append(f"{name}={path}")
        return subprocess.run(args, capture_output=True, text=True)


class CheckFreshness(unittest.TestCase):
    def test_fresh_and_current_passes(self):
        r = check({"edge": image(), "gen": image()})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("edge", r.stdout)

    def test_older_than_max_age_fails(self):
        r = check({"edge": image(), "gen": image(created="2026-11-05T05:46:59Z")})
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("gen", r.stdout)
        self.assertIn("older than 8 days", r.stdout)

    def test_exactly_max_age_passes(self):
        r = check({"edge": image(created="2026-11-05T05:47:00Z")})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_max_age_zero_fails_any_image(self):
        r = check({"edge": image(created="2026-11-13T05:46:00Z")}, max_age="0")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_timestamp_with_offset_and_nanoseconds(self):
        # 2026-11-05T07:47:00.5+02:00 is 05:47:00.5 UTC: 7 days 23:59:59.5 old, within 8 days.
        r = check({"edge": image(created="2026-11-05T07:47:00.500000000+02:00")})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = check({"edge": image(created="2026-11-05T07:46:59.999999999+02:00")})
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_nginx_behind_upstream_fails_numeric_compare(self):
        # As strings "1.31.9" > "1.31.10"; as versions it is lower.
        r = check({"edge": image(nginx="1.31.9")})
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("NGINX_VERSION 1.31.9 is lower than upstream 1.31.10", r.stdout)

    def test_nginx_ahead_of_resolver_passes(self):
        r = check({"edge": image(nginx="1.31.11")})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_reports_every_problem(self):
        r = check({"edge": image(created="2026-10-01T00:00:00Z", nginx="1.29.0"), "gen": image()})
        self.assertEqual(r.returncode, 1)
        self.assertIn("older than", r.stdout)
        self.assertIn("lower than upstream", r.stdout)

    def test_missing_versions_label_is_an_error(self):
        r = check({"edge": image(labels={"org.kickedro.build-key": "x"})})
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("org.kickedro.versions", r.stderr)

    def test_missing_created_is_an_error(self):
        r = check({"edge": image(created=None)})
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_unparsable_input_is_an_error(self):
        for bad in ("not json", json.dumps({"edge": image()}), json.dumps(image(nginx="1.31.x"))):
            with self.subTest(bad=bad[:30]):
                self.assertEqual(check({"edge": bad}).returncode, 2)
        self.assertEqual(check({"edge": image()}, versions="CRS_VERSION=v4.30.0\n").returncode, 2)
        self.assertEqual(check({"edge": image()}, max_age="eight").returncode, 2)
        self.assertEqual(check({}).returncode, 2)


if __name__ == "__main__":
    unittest.main()
