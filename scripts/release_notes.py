#!/usr/bin/env python3
"""Contents, manifest and release notes of a versioned release.

Usage:
  release_notes.py contents --versions FILE --key-inputs FILE --gen-modules FILE --out FILE
  release_notes.py manifest --contents FILE --version X.Y.Z --commit SHA --key KEY
                            --edge REPOSITORY@DIGEST --gen REPOSITORY@DIGEST --out FILE
  release_notes.py notes --manifest FILE [--previous FILE] [--prs FILE] [--changelog FILE] --out FILE

contents: what is inside the two tested images, as JSON: {"versions": {KEY: VALUE}, "packages": {"edge": {name:
version}, "gen": {...}}, "go": "go1.x.y", "go_modules": {path: version}}. FILE for --versions is the output of
scripts/resolve_versions.py; --key-inputs is the text scripts/build_key.sh writes with BUILD_KEY_INPUTS (the sections
"[edge packages]" and "[gen packages]" hold dpkg-query lines "<status> <name> <version>", only status "ii" counts);
--gen-modules is `go version -m` of docker-gen (shipped in the gen image). A module replaced by a "=>" line is listed
with the replacement's version.
manifest: contents plus schema, version, commit, build key and the digests of the images. Same inputs give the same
bytes (sorted keys, no timestamps), so a re-run can be compared byte for byte.
notes: Markdown release notes from a manifest; with --previous (the manifest of the previous release) it lists what
changed, without it every list is complete. --prs is GitHub's generated notes (Markdown) for "Changes in this
repository", without the authors' @-mentions: " by @login" is removed from each pull request line ("* title by @login
in URL") and the "New Contributors" section is dropped; the pull request links stay. Its headings are demoted one
level (## → ###) to sit below that section's heading. When it lists no pull request (no "* " or "- " line), the
section starts with a rebuild note, which is also all it says without --prs. For a minor release (X.Y.0) with
--changelog, the "> **Upgrading:**" block of its "## [X.Y.0]" section and a link to that section come first; a
missing file or section only prints a warning on stderr. Notes never exceed 100000 characters: past that,
the package lists give way to a pointer to the manifest.
Exit 0 on success, 2 on unusable input (unreadable or malformed file, missing section, bad argument), with a one-line
message on stderr.
"""
import argparse
import json
import re
import sys

MAX_NOTES = 100000
MANIFEST_SCHEMA = 1
REPO_URL = "https://github.com/KickedRo/edge-proxy"
SIGNER_IDENTITY = REPO_URL + "/.github/workflows/build.yml@refs/heads/main"  # as docs/verify.md
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
DETAILS_OVER = 10  # a list with more lines than this is folded
COMPONENTS = {
    "NGINX_VERSION": "nginx",
    "MODSECURITY_VERSION": "ModSecurity",
    "MODSECURITY_NGINX_VERSION": "ModSecurity-nginx connector",
    "CRS_VERSION": "OWASP CRS",
    "DOCKER_GEN_VERSION": "docker-gen",
    "GO_VERSION": "Go (docker-gen build)",
    "NGINX_PROXY_REF": "nginx-proxy (commit)",
}
IMAGES = ("edge", "gen")


class InputError(Exception):
    pass


def read(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise InputError(f"{what}: cannot read {path}: {e}")


def write(path, text):
    try:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
    except OSError as e:
        raise InputError(f"cannot write {path}: {e}")


def dump(data):
    return json.dumps(data, sort_keys=True, indent=2, ensure_ascii=False) + "\n"


def load_json(path, what):
    try:
        data = json.loads(read(path, what))
    except ValueError as e:
        raise InputError(f"{what}: {path} is not JSON: {e}")
    if not isinstance(data, dict):
        raise InputError(f"{what}: {path} is not a JSON object")
    return data


# ---- contents ---------------------------------------------------------------------------------------------------

def parse_versions(text, path):
    versions = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        key, sep, value = line.partition("=")
        if not sep or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or not value:
            raise InputError(f"versions: {path}: not KEY=VALUE: {line!r}")
        versions[key] = value
    if "NGINX_VERSION" not in versions:
        raise InputError(f"versions: {path} is not a versions file (no NGINX_VERSION)")
    return versions


def parse_packages(text, path):
    """{"edge": {name: version}, "gen": {...}} from the "[<image> packages]" sections of the build-key inputs."""
    sections = {}
    current = None
    for line in text.splitlines():
        m = re.fullmatch(r"\[(.+)\]", line)
        if m:
            current = m.group(1)
            sections[current] = []
        elif current is not None:
            sections[current].append(line)
    packages = {}
    for image in IMAGES:
        name = f"{image} packages"
        if name not in sections:
            raise InputError(f"key inputs: {path} has no [{name}] section")
        found = {}
        for line in sections[name]:
            fields = line.split()
            if not fields or fields[0] != "ii":
                continue  # removed, half-installed or unknown packages are not in the image
            if len(fields) != 3:
                raise InputError(f"key inputs: {path}: malformed package line in [{name}]: {line!r}")
            found[fields[1]] = fields[2]
        if not found:
            raise InputError(f"key inputs: {path}: no installed package in [{name}]")
        packages[image] = found
    return packages


def parse_go_modules(text, path):
    """(go version, {module path: version}) from `go version -m` output: "mod" and "dep" lines, "=>" replaces."""
    lines = text.splitlines()
    m = re.fullmatch(r"\S+: (go\d\S*)", lines[0]) if lines else None
    if not m:
        raise InputError(f"go modules: {path} does not start with 'BINARY: goX.Y.Z' (go version -m output)")
    modules = {}
    last = None
    for line in lines[1:]:
        fields = line.strip().split("\t")
        if fields[0] in ("mod", "dep") and len(fields) >= 3:
            last = fields[1]
            modules[last] = fields[2]
        elif fields[0] == "=>" and last is not None and len(fields) >= 3:
            modules[last] = fields[2]
    if not any(l.startswith("\tdep\t") or l.startswith("dep\t") for l in lines):
        raise InputError(f"go modules: {path} lists no dep line")
    return m.group(1), modules


def cmd_contents(args):
    versions = parse_versions(read(args.versions, "versions"), args.versions)
    packages = parse_packages(read(args.key_inputs, "key inputs"), args.key_inputs)
    go, modules = parse_go_modules(read(args.gen_modules, "go modules"), args.gen_modules)
    write(args.out, dump({"versions": versions, "packages": packages, "go": go, "go_modules": modules}))


# ---- manifest ---------------------------------------------------------------------------------------------------

def image_ref(text, what):
    m = re.fullmatch(r"([a-z0-9][a-z0-9._/-]*)@(sha256:[0-9a-f]{64})", text)
    if not m:
        raise InputError(f"{what}: {text!r} is not REPOSITORY@sha256:DIGEST")
    return {"repository": m.group(1), "digest": m.group(2)}


def cmd_manifest(args):
    contents = load_json(args.contents, "contents")
    for key in ("versions", "packages", "go", "go_modules"):
        if key not in contents:
            raise InputError(f"contents: {args.contents} has no {key!r}")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.version):
        raise InputError(f"version: {args.version!r} is not X.Y.Z")
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        raise InputError(f"commit: {args.commit!r} is not a full commit id")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.key):
        raise InputError(f"key: {args.key!r} is not a build key (sha256:...)")
    manifest = dict(contents)
    manifest.update({
        "schema": MANIFEST_SCHEMA,
        "version": args.version,
        "commit": args.commit,
        "build_key": args.key,
        "images": {"edge": image_ref(args.edge, "edge"), "gen": image_ref(args.gen, "gen")},
    })
    write(args.out, dump(manifest))


# ---- notes ------------------------------------------------------------------------------------------------------

def load_manifest(path, what):
    m = load_json(path, what)
    if m.get("schema") != MANIFEST_SCHEMA:
        raise InputError(f"{what}: {path} has schema {m.get('schema')!r}, expected {MANIFEST_SCHEMA}")
    try:
        ok = (isinstance(m["version"], str) and isinstance(m["versions"], dict) and isinstance(m["go"], str)
              and isinstance(m["go_modules"], dict) and isinstance(m["packages"], dict)
              and all(isinstance(m["packages"][i], dict) for i in IMAGES)
              and all(isinstance(m["images"][i]["repository"], str) and isinstance(m["images"][i]["digest"], str)
                      for i in IMAGES))
    except (KeyError, TypeError):
        ok = False
    if not ok:
        raise InputError(f"{what}: {path} is not a release manifest")
    return m


def folded(title, lines):
    """A bullet list, inside <details> when it is long."""
    body = "\n".join(lines)
    if len(lines) > DETAILS_OVER:
        return f"<details>\n<summary>{title} ({len(lines)})</summary>\n\n{body}\n\n</details>\n"
    return f"**{title} ({len(lines)})**\n\n{body}\n"


def diff_lists(old, new):
    """Folded lists of what was added, removed and changed between two {name: version} maps; "" when equal."""
    added = [f"- `{n}` {new[n]}" for n in sorted(new.keys() - old.keys())]
    removed = [f"- `{n}` {old[n]}" for n in sorted(old.keys() - new.keys())]
    changed = [f"- `{n}` {old[n]} → {new[n]}" for n in sorted(old.keys() & new.keys()) if old[n] != new[n]]
    parts = [folded(t, l) for t, l in (("Added", added), ("Removed", removed), ("Changed", changed)) if l]
    return "\n".join(parts)


def full_list(items):
    return folded("Installed", [f"- `{n}` {v}" for n, v in sorted(items.items())])


def packages_section(m, prev):
    out = ["## Packages\n"]
    for image in IMAGES:
        out.append(f"### {image}\n")
        pkgs = m["packages"][image]
        if prev is None:
            out.append(full_list(pkgs))
        else:
            d = diff_lists(prev["packages"][image], pkgs)
            out.append(d if d else "No package changes.\n")
        if image == "gen":
            out.append("#### Go\n")
            if prev is None:
                out.append(f"`{m['go']}`\n")
            elif prev["go"] != m["go"]:
                out.append(f"`{prev['go']}` → `{m['go']}`\n")
            else:
                out.append(f"`{m['go']}`, unchanged.\n")
            out.append("#### Go modules\n")
            if prev is None:
                out.append(full_list(m["go_modules"]))
            else:
                d = diff_lists(prev["go_modules"], m["go_modules"])
                out.append(d if d else "No module changes.\n")
    return "\n".join(out)


def upstream_section(m, prev):
    out = ["## Upstream\n"]
    versions = m["versions"]
    names = sorted(versions, key=lambda k: (k not in COMPONENTS, list(COMPONENTS).index(k) if k in COMPONENTS else 0, k))
    label = lambda k: COMPONENTS.get(k, k)
    if prev is None:
        out.append("First versioned release: no earlier version to compare with.\n")
    else:
        old = prev["versions"]
        changes = [f"- {label(k)}: {old.get(k, '(none)')} → {versions.get(k, '(none)')}"
                   for k in sorted(set(old) | set(versions), key=lambda k: names.index(k) if k in names else len(names))
                   if old.get(k) != versions.get(k)]
        out.append(f"Changed since {prev['version']}:\n\n" + "\n".join(changes) + "\n" if changes
                   else f"No upstream version changed since {prev['version']}.\n")
    out.append("| Component | Version |\n| --- | --- |")
    out.extend(f"| {label(k)} | `{versions[k]}` |" for k in names)
    return "\n".join(out) + "\n"


def images_section(m):
    version = m["version"]
    out = ["## Images\n"]
    for image in IMAGES:
        i = m["images"][image]
        out.append(f"- **{image}**: `{i['repository']}:{version}`, pinned `{i['repository']}@{i['digest']}`")
    out.append("")
    out.append("Verify before you trust them (needs `cosign` 3.x and `gh`; details in "
               f"[docs/verify.md]({REPO_URL}/blob/main/docs/verify.md)):\n")
    out.append("```sh")
    out.append(f"ID='{SIGNER_IDENTITY}'")
    out.append(f"ISSUER={OIDC_ISSUER}")
    out.append("")
    for image in IMAGES:
        i = m["images"][image]
        out.append(f"cosign verify {i['repository']}@{i['digest']} --certificate-identity \"$ID\" "
                   "--certificate-oidc-issuer \"$ISSUER\"")
    for image in IMAGES:
        i = m["images"][image]
        out.append(f"gh attestation verify oci://{i['repository']}@{i['digest']} --repo KickedRo/edge-proxy "
                   "--cert-identity \"$ID\"")
    out.append("```")
    return "\n".join(out) + "\n"


def github_anchor(heading):
    """The id GitHub gives a heading: lowercase, punctuation dropped (not - or _), spaces to hyphens."""
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")


def upgrading_block(changelog_path, version):
    """The top lines for a minor release, or "" (with a warning on stderr) when the changelog cannot give them."""
    try:
        with open(changelog_path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        print(f"release_notes: warning: cannot read {changelog_path} ({e}); no Upgrading block", file=sys.stderr)
        return ""
    start = next((n for n, l in enumerate(lines) if re.match(rf"##\s+\[{re.escape(version)}\]", l)), None)
    if start is None:
        print(f"release_notes: warning: {changelog_path} has no '## [{version}]' section; no Upgrading block",
              file=sys.stderr)
        return ""
    heading = lines[start][2:].strip()
    block = []
    rest = iter(lines[start + 1:])
    for l in rest:  # the block is the first quote of the section, introduced by "> **Upgrading:**"
        if l.strip():
            if l.startswith("> **Upgrading:**"):
                block.append(l)
                for q in rest:
                    if not q.startswith(">"):
                        break
                    block.append(q)
            break
    link = f"Full changelog for {version}: [CHANGELOG.md]({REPO_URL}/blob/v{version}/CHANGELOG.md#{github_anchor(heading)})\n"
    return ("\n".join(block) + "\n\n" if block else "") + link + "\n"


REBUILD = "None: a rebuild for upstream and security updates."
LIST_ITEM = re.compile(r"[*-] ")
# " by @login" at the end of a pull request line, before " in URL" (GitHub: "* title by @login in URL"; a bot's
# login ends in "[bot]"). Only the last one: a title may say "by" itself.
AUTHOR = re.compile(r"[ \t]+by @\S+(?= in \S+[ \t]*$)")
NEW_CONTRIBUTORS = re.compile(r" {0,3}#{1,6}[ \t]+New Contributors[ \t]*")
FENCE = re.compile(r" {0,3}(`{3,}|~{3,})(.*)")
HEADING = re.compile(r"^( {0,3})(#{1,5})(?=[ \t]|$)")


def without_authors(text):
    """GitHub's generated notes without the authors' @-mentions: " by @login" leaves each pull request line, and the
    "New Contributors" section (its heading and its list, each line "* @login made their first contribution ...")
    is dropped."""
    out, dropping = [], False
    for line in text.split("\n"):
        if NEW_CONTRIBUTORS.fullmatch(line):
            dropping = True
            continue
        if dropping:
            if not line.strip() or LIST_ITEM.match(line):
                continue
            dropping = False  # the section ends at the first line that is neither blank nor a list item
        if LIST_ITEM.match(line):
            line = AUTHOR.sub("", line, count=1)
        out.append(line)
    return "\n".join(out)


def changes_section(prs):
    text = without_authors(prs or "").strip()
    listed = any(LIST_ITEM.match(line) for line in text.split("\n"))
    text = demote_headings(text)
    if not listed:  # no pull request: GitHub still returns the "**Full Changelog**" link, which stays
        text = REBUILD + ("\n\n" + text if text else "")
    return "## Changes in this repository\n\n" + text + "\n"


def demote_headings(text):
    """Every ATX heading one level lower (# → ##, ## → ###, ...; ###### stays), so a Markdown text (GitHub's
    generated notes) sits below the section heading it is put under. Fenced code blocks are left as they are."""
    out, fence = [], None
    for line in text.split("\n"):
        m = FENCE.fullmatch(line)
        if fence is None:
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):  # an opening fence (CommonMark)
                fence = m.group(1)
            else:
                line = HEADING.sub(r"\1\2#", line, count=1)
        elif m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
            fence = None  # the closing fence: same character, at least as long, nothing after it
        out.append(line)
    return "\n".join(out)


def build_notes(m, prev, prs, changelog, capped):
    parts = []
    version = m["version"]
    if changelog and version.endswith(".0"):
        parts.append(upgrading_block(changelog, version))
    parts.append(changes_section(prs))
    parts.append(upstream_section(m, prev))
    if capped:
        parts.append("## Packages\n\nThe package lists are too long for these notes. "
                     "`manifest.json`, attached to this release, lists every package and Go module"
                     + (f"; compare it with the one of {prev['version']}." if prev else ".") + "\n")
    else:
        parts.append(packages_section(m, prev))
    parts.append(images_section(m))
    return "\n".join(p for p in parts if p)


def cmd_notes(args):
    m = load_manifest(args.manifest, "manifest")
    prev = load_manifest(args.previous, "previous manifest") if args.previous else None
    prs = read(args.prs, "prs") if args.prs else None
    notes = build_notes(m, prev, prs, args.changelog, False)
    if len(notes) > MAX_NOTES:
        notes = build_notes(m, prev, prs, args.changelog, True)
    if len(notes) > MAX_NOTES:
        raise InputError(f"notes: {len(notes)} characters even without the package lists (limit {MAX_NOTES})")
    write(args.out, notes)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="command", required=True)
    c = sub.add_parser("contents")
    for name in ("versions", "key-inputs", "gen-modules", "out"):
        c.add_argument("--" + name, required=True)
    c.set_defaults(run=cmd_contents)
    mf = sub.add_parser("manifest")
    for name in ("contents", "version", "commit", "key", "edge", "gen", "out"):
        mf.add_argument("--" + name, required=True)
    mf.set_defaults(run=cmd_manifest)
    n = sub.add_parser("notes")
    n.add_argument("--manifest", required=True)
    n.add_argument("--out", required=True)
    for name in ("previous", "prs", "changelog"):
        n.add_argument("--" + name)
    n.set_defaults(run=cmd_notes)

    args = p.parse_args(argv)  # a bad argument exits 2 with argparse's usage message
    try:
        args.run(args)
    except InputError as e:
        print(f"release_notes: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
