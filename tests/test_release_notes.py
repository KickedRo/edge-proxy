import copy, json, os, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "release_notes.py")
FIX = os.path.join(ROOT, "tests", "fixtures", "release")
COMMIT = "a" * 40
KEY = "sha256:" + "b" * 64
EDGE = "ghcr.io/example/edge-proxy@sha256:" + "1" * 64
GEN = "ghcr.io/example/edge-proxy-gen@sha256:" + "2" * 64

CHANGELOG = """# Changelog

## [0.3.0] - 2026-12-01

> **Upgrading:** nothing for 0.3.0.

Other text.

## [0.2.0] - 2026-11-20

> **Upgrading:** the block page moved.
> Set `BLOCK_PAGE=legacy` to keep the old one.

### Changed
- something

## [0.1.0] - 2026-11-16

First release.
"""


def run(*args):
    return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True)


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def path(self, name):
        return os.path.join(self.tmp, name)

    def write(self, name, text):
        with open(self.path(name), "w") as f:
            f.write(text)
        return self.path(name)

    def read(self, path):
        with open(path) as f:
            return f.read()

    def fixture(self, name):
        return os.path.join(FIX, name)

    def contents(self, versions=None, key_inputs=None, gen_modules=None, out="contents.json"):
        return run("contents", "--versions", versions or self.fixture("versions.env"),
                   "--key-inputs", key_inputs or self.fixture("key-inputs.txt"),
                   "--gen-modules", gen_modules or self.fixture("go-modules.txt"), "--out", self.path(out))

    def contents_data(self):
        r = self.contents()
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(self.read(self.path("contents.json")))

    def manifest(self, data, version, name, edge=EDGE, gen=GEN, key=KEY, commit=COMMIT):
        c = self.write(name + ".contents.json", json.dumps(data))
        r = run("manifest", "--contents", c, "--version", version, "--commit", commit, "--key", key,
                "--edge", edge, "--gen", gen, "--out", self.path(name))
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.path(name)

    def notes(self, manifest, *extra):
        r = run("notes", "--manifest", manifest, *extra, "--out", self.path("notes.md"))
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.read(self.path("notes.md")), r.stderr


class ContentsTest(Base):
    def test_contents_parses_packages_and_versions(self):
        data = self.contents_data()
        self.assertEqual(data["versions"]["NGINX_VERSION"], "1.31.8")
        self.assertEqual(data["versions"]["NGINX_PROXY_REF"], "bff2cddfece8e4f2c6d00b62ba45b8214c4727c5")
        self.assertEqual(len(data["versions"]), 7)
        edge, gen = data["packages"]["edge"], data["packages"]["gen"]
        self.assertEqual(edge["nginx"], "1.31.8-1~trixie")  # tilde
        self.assertEqual(edge["libssl3t64:amd64"], "3.5.7-1~deb13u3")  # architecture-qualified name
        self.assertEqual(edge["libc6:amd64"], "2.41-12+deb13u4")  # +debXuY
        self.assertEqual(edge["zlib1g:amd64"], "1:1.3.dfsg+really1.3.1-1+deb13u1")  # epoch
        self.assertEqual(edge["nginx-module-njs"], "1.31.8+1.0.2-1~trixie")
        self.assertNotIn("libold1:amd64", edge)  # status "rc": removed, config files left
        self.assertNotIn("libnever", edge)  # status "un": never installed
        self.assertEqual(len(edge), 11)
        self.assertEqual(len(gen), 6)
        self.assertNotIn("nginx", gen)  # each image has its own list
        self.assertEqual(data["go"], "go1.27.4")

    def test_contents_go_modules_with_replacement(self):
        mods = self.contents_data()["go_modules"]
        self.assertEqual(mods["dario.cat/mergo"], "v1.0.2")
        self.assertEqual(mods["github.com/nginx-proxy/docker-gen"], "v0.0.0-20260711084634-497e50d07d3a+dirty")
        self.assertEqual(mods["example.com/forked"], "v1.0.1-fixed")  # the replacement's version
        self.assertNotIn("example.com/fork-of-forked", mods)
        self.assertNotIn("-buildmode=exe", mods)  # "build" lines are not modules
        self.assertEqual(len(mods), 6)

    def test_contents_matches_expected_file(self):
        self.assertEqual(self.contents().returncode, 0)
        self.assertEqual(self.read(self.path("contents.json")), self.read(self.fixture("contents.expected.json")))

    def test_contents_refuses_missing_section(self):
        text = self.read(self.fixture("key-inputs.txt")).replace("[gen packages]", "[gen stuff]")
        r = self.contents(key_inputs=self.write("inputs.txt", text))
        self.assertEqual(r.returncode, 2)
        self.assertIn("[gen packages]", r.stderr)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)
        self.assertFalse(os.path.exists(self.path("contents.json")))

    def test_contents_refuses_unusable_inputs(self):
        bad = self.write("bad", "nothing useful\n")
        for kwargs in ({"versions": bad}, {"gen_modules": bad}, {"versions": self.path("missing")}):
            r = self.contents(**kwargs)
            self.assertEqual(r.returncode, 2, kwargs)
            self.assertEqual(len(r.stderr.strip().splitlines()), 1, r.stderr)
        r = self.contents(key_inputs=self.write("i", "[edge packages]\nii  onlyname\n[gen packages]\nii  a 1\n"))
        self.assertEqual(r.returncode, 2)
        self.assertIn("malformed", r.stderr)


class ManifestTest(Base):
    def test_manifest_is_deterministic(self):
        data = self.contents_data()
        a = self.manifest(data, "0.1.0", "a.json")
        b = self.manifest(data, "0.1.0", "b.json")
        with open(a, "rb") as fa, open(b, "rb") as fb:
            raw = fa.read()
            self.assertEqual(raw, fb.read())
        self.assertTrue(raw.endswith(b"}\n"))
        text = raw.decode()
        self.assertEqual(text, json.dumps(json.loads(text), sort_keys=True, indent=2, ensure_ascii=False) + "\n")
        m = json.loads(text)
        self.assertEqual(m["schema"], 1)
        self.assertEqual((m["version"], m["commit"], m["build_key"]), ("0.1.0", COMMIT, KEY))
        self.assertEqual(m["images"], {"edge": {"repository": "ghcr.io/example/edge-proxy", "digest": "sha256:" + "1" * 64},
                                       "gen": {"repository": "ghcr.io/example/edge-proxy-gen", "digest": "sha256:" + "2" * 64}})
        for key in data:
            self.assertEqual(m[key], data[key])

    def test_manifest_refuses_bad_arguments(self):
        c = self.write("c.json", json.dumps(self.contents_data()))
        good = {"--version": "0.1.0", "--commit": COMMIT, "--key": KEY, "--edge": EDGE, "--gen": GEN}
        for name, value in (("--version", "0.1"), ("--version", "0.01.0"), ("--commit", "abc"), ("--key", "x"),
                            ("--edge", "ghcr.io/example/edge-proxy:latest"), ("--gen", "ghcr.io/x@sha256:12")):
            args = dict(good, **{name: value})
            flat = [x for kv in args.items() for x in kv]
            r = run("manifest", "--contents", c, *flat, "--out", self.path("m.json"))
            self.assertEqual(r.returncode, 2, (name, value))
            self.assertEqual(len(r.stderr.strip().splitlines()), 1, r.stderr)
        self.assertFalse(os.path.exists(self.path("m.json")))


class NotesTest(Base):
    def current(self, version="0.1.1"):
        return self.manifest(self.contents_data(), version, "current.json")

    def previous_data(self):
        """The previous release: an older nginx and CRS, one package gone, one new, two changed, an older module."""
        d = copy.deepcopy(self.contents_data())
        d["versions"]["NGINX_VERSION"] = "1.31.7"
        d["versions"]["CRS_VERSION"] = "v4.29.0"
        d["packages"]["edge"]["libold1:amd64"] = "1.0-1"  # in the previous release, gone now
        del d["packages"]["edge"]["tzdata"]  # added since
        d["packages"]["edge"]["libc6:amd64"] = "2.41-12+deb13u3"
        d["packages"]["gen"]["zlib1g:amd64"] = "1:1.3.dfsg+really1.3.1-1"
        d["go"] = "go1.27.3"
        d["go_modules"]["github.com/BurntSushi/toml"] = "v1.5.0"
        d["go_modules"]["example.com/removed"] = "v0.1.0"
        return d

    def test_notes_first_release_lists_everything(self):
        text, _ = self.notes(self.current("0.1.0"), "--prs", self.write("prs.md", "* Add a thing by @someone in #1"))
        self.assertIn("First versioned release", text)
        self.assertNotIn("→", text)  # nothing to compare with
        self.assertIn("* Add a thing by @someone in #1", text)
        # sections in order
        order = [text.index(h) for h in ("## Changes in this repository", "## Upstream", "## Packages", "## Images")]
        self.assertEqual(order, sorted(order))
        # every upstream version, every package, Go and the modules
        for needle in ("| nginx | `1.31.8` |", "| OWASP CRS | `v4.30.0` |", "`libc6:amd64` 2.41-12+deb13u4",
                       "`zlib1g:amd64` 1:1.3.dfsg+really1.3.1-1+deb13u1", "`nginx` 1.31.8-1~trixie",
                       "`go1.27.4`", "`github.com/BurntSushi/toml` v1.6.0"):
            self.assertIn(needle, text)
        self.assertEqual(text.count("`libc6:amd64` 2.41-12+deb13u4"), 2)  # once per image
        self.assertNotIn("libold1", text)
        self.assertIn("<details>", text)  # 11 edge packages: folded
        # images: tags, digests and the verification commands of docs/verify.md
        self.assertIn("`ghcr.io/example/edge-proxy:0.1.0`", text)
        self.assertIn("`ghcr.io/example/edge-proxy-gen@sha256:" + "2" * 64 + "`", text)
        self.assertIn("cosign verify " + EDGE, text)
        self.assertIn("cosign verify " + GEN, text)
        self.assertIn("gh attestation verify oci://" + EDGE, text)
        self.assertIn("--certificate-oidc-issuer", text)
        self.assertIn("https://github.com/KickedRo/edge-proxy/.github/workflows/build.yml@refs/heads/main", text)
        self.assertEqual(text, self.read(self.fixture("notes-first.expected.md")))

    def test_notes_diff_added_removed_changed(self):
        prev = self.manifest(self.previous_data(), "0.1.0", "previous.json", key="sha256:" + "c" * 64)
        text, _ = self.notes(self.current(), "--previous", prev)
        self.assertNotIn("First versioned release", text)
        self.assertIn("Changed since 0.1.0", text)
        self.assertIn("- nginx: 1.31.7 → 1.31.8", text)
        self.assertIn("- OWASP CRS: v4.29.0 → v4.30.0", text)
        self.assertNotIn("- docker-gen:", text)  # unchanged components are only in the table
        self.assertIn("| docker-gen | `0.17.2` |", text)
        self.assertIn("- `libc6:amd64` 2.41-12+deb13u3 → 2.41-12+deb13u4", text)
        self.assertIn("**Added (1)**\n\n- `tzdata` 2026f-0+deb13u1", text)
        self.assertIn("**Removed (1)**\n\n- `libold1:amd64` 1.0-1", text)
        self.assertIn("- `zlib1g:amd64` 1:1.3.dfsg+really1.3.1-1 → 1:1.3.dfsg+really1.3.1-1+deb13u1", text)
        self.assertIn("`go1.27.3` → `go1.27.4`", text)
        self.assertIn("- `github.com/BurntSushi/toml` v1.5.0 → v1.6.0", text)
        self.assertIn("**Removed (1)**\n\n- `example.com/removed` v0.1.0", text)
        self.assertNotIn("`ca-certificates`", text)  # unchanged packages stay out of the diff
        self.assertNotIn("<details>", text)  # short lists are not folded
        self.assertEqual(text, self.read(self.fixture("notes-diff.expected.md")))

    def test_notes_unchanged_repository_says_rebuild(self):
        prev = self.manifest(self.contents_data(), "0.1.0", "previous.json")
        text, _ = self.notes(self.current(), "--previous", prev)
        self.assertIn("None: a rebuild for upstream and security updates.", text)
        self.assertIn("No upstream version changed since 0.1.0.", text)
        self.assertEqual(text.count("No package changes."), 2)  # edge and gen
        self.assertIn("No module changes.", text)
        text2, _ = self.notes(self.current(), "--previous", prev, "--prs", self.write("empty.md", "\n"))
        self.assertEqual(text, text2)  # an empty --prs file is the same as none

    def test_notes_minor_copies_upgrading_block(self):
        cl = self.write("CHANGELOG.md", CHANGELOG)
        text, err = self.notes(self.current("0.2.0"), "--changelog", cl)
        self.assertEqual(err, "")
        self.assertTrue(text.startswith("> **Upgrading:** the block page moved.\n> Set `BLOCK_PAGE=legacy` to keep the old one.\n\n"), text[:200])
        self.assertNotIn("nothing for 0.3.0", text)  # the section of this version only
        self.assertEqual(text.count("Upgrading"), 1)
        self.assertIn("(https://github.com/KickedRo/edge-proxy/blob/v0.2.0/CHANGELOG.md#020---2026-11-20)", text)
        self.assertLess(text.index("CHANGELOG.md#"), text.index("## Changes in this repository"))
        # a patch release gets neither block nor link
        text, err = self.notes(self.current("0.2.1"), "--changelog", cl)
        self.assertNotIn("Upgrading", text)
        self.assertNotIn("CHANGELOG", text)
        self.assertEqual(err, "")

    def test_notes_minor_without_upgrading_block_still_links(self):
        cl = self.write("CHANGELOG.md", "## [0.1.0] - 2026-11-16\n\nFirst release.\n\n> A quote, not the block.\n")
        text, err = self.notes(self.current("0.1.0"), "--changelog", cl)
        self.assertEqual(err, "")
        self.assertTrue(text.startswith("Full changelog for 0.1.0:"), text[:100])
        self.assertNotIn("A quote", text)

    def test_notes_minor_missing_changelog_section_warns(self):
        cl = self.write("CHANGELOG.md", CHANGELOG)
        for changelog, what in ((cl, "## [0.4.0]"), (self.path("nope.md"), "nope.md")):
            text, err = self.notes(self.current("0.4.0"), "--changelog", changelog)  # exit 0: never fails over docs
            self.assertIn("warning", err)
            self.assertIn(what, err)
            self.assertEqual(len(err.strip().splitlines()), 1)
            self.assertTrue(text.startswith("## Changes in this repository"), text[:100])
            self.assertNotIn("Upgrading", text)
            self.assertNotIn("CHANGELOG", text)

    def big_data(self, n, changed):
        """n packages per image with long names: a Debian point release that changes all of them."""
        d = copy.deepcopy(self.contents_data())
        for image in ("edge", "gen"):
            d["packages"][image] = {f"lib{image}-package-with-a-long-name-{'x' * 60}-{i:05d}": "1.0-1" for i in range(n)}
        return d

    def test_notes_capped_with_manifest_pointer(self):
        old = self.big_data(1500, False)
        new = copy.deepcopy(old)
        for image in ("edge", "gen"):
            for name in new["packages"][image]:
                new["packages"][image][name] = "1:2.39.5-1+deb13u1~really-a-long-version-string-for-the-test"
        prev = self.manifest(old, "0.1.0", "previous.json")
        cur = self.manifest(new, "0.1.1", "current.json")
        text, _ = self.notes(cur, "--previous", prev)
        self.assertLessEqual(len(text), 100000)
        self.assertIn("`manifest.json`", text)
        self.assertNotIn("lib" + "edge-package-with-a-long-name", text)  # the lists are gone
        for heading in ("## Changes in this repository", "## Upstream", "## Images"):
            self.assertIn(heading, text)
        # the first release is capped the same way
        text, _ = self.notes(self.manifest(self.big_data(1500, False), "0.1.0", "first.json"))
        self.assertLessEqual(len(text), 100000)
        self.assertIn("`manifest.json`", text)
        self.assertIn("First versioned release", text)

    def test_notes_150_changed_packages_stay_complete_and_under_the_cap(self):
        old = self.big_data(160, False)
        new = copy.deepcopy(old)
        for image in ("edge", "gen"):
            for name in new["packages"][image]:
                new["packages"][image][name] = "1.0-1+deb13u1"
        text, _ = self.notes(self.manifest(new, "0.1.1", "c.json"), "--previous", self.manifest(old, "0.1.0", "p.json"))
        self.assertLess(len(text), 100000)
        self.assertEqual(text.count("1.0-1 → 1.0-1+deb13u1"), 320)
        self.assertNotIn("manifest.json", text)
        self.assertEqual(text.count("<details>"), 2)  # one folded list of changes per image

    def test_notes_refuses_unusable_manifests(self):
        good = self.current()
        for content in ("not json", "[]", json.dumps({"schema": 2}), json.dumps({"schema": 1})):
            bad = self.write("bad.json", content)
            for args in (("--manifest", bad), ("--manifest", good, "--previous", bad)):
                r = run("notes", *args, "--out", self.path("n.md"))
                self.assertEqual(r.returncode, 2, content)
                self.assertEqual(len(r.stderr.strip().splitlines()), 1, r.stderr)
        self.assertFalse(os.path.exists(self.path("n.md")))


if __name__ == "__main__":
    unittest.main()
