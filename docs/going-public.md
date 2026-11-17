# Repository protections

A record of how this repository is protected, and what is still to do. It is not a how-to for users.

## What is switched on

**Account**
- Required two-factor authentication for the organisation that owns the repository.

**Repository security**
- Secret scanning and push protection.
- Dependabot alerts and security updates. Version updates for GitHub Actions are configured in
  `.github/dependabot.yml`.
- Private vulnerability reporting (see [SECURITY.md](../SECURITY.md)).

**The `main` branch**
- Changes only through a pull request (no direct pushes). No approvals are required, so a maintainer can merge their
  own pull request, but the checks below must pass.
- The checks `resolve` and `build-test` from GitHub Actions are required, and the branch must be up to date with `main`
  before it merges.
- Linear history, all conversations resolved, no force-push, no deletion. The rules apply to administrators too.
- Only squash merges are allowed, and merged branches are deleted. Required commit signing is not used: it blocks
  squash merges of unsigned branch commits (the squash commit itself is signed by GitHub).

**GitHub Actions**
- Allowed actions: those owned by GitHub, plus `docker/build-push-action`, `docker/setup-buildx-action`,
  `docker/login-action`, `docker/metadata-action` and `sigstore/cosign-installer`.
- Pinning by full commit SHA is enforced.
- The default token is read-only; each job asks for the permissions it needs.
- Workflows of pull requests from forks need a maintainer's approval before they run.

**Before every push**
- Maintainers scan the outgoing commits for their own internal names (hostnames, address ranges, customer and
  server names) before pushing, and push only reviewed commits. The repository holds only generic example values
  (`example.com`, and the documentation address ranges of RFC 5737 and RFC 3849).

**Packages**
- Both container packages (`edge-proxy` and `edge-proxy-gen`) on ghcr.io are public, so images can be pulled and
  their signatures checked with `cosign` [without logging in](verify.md) (`gh attestation verify` needs a GitHub login).

## Still to do

Two settings for versioned releases (see [maintenance.md](maintenance.md#versions)). They are maintainer actions,
made by hand in the repository's settings on GitHub. Switch both on **before the first release** (`0.1.0`, which the
first push run on `main` with versioned releases publishes): release immutability applies only to Releases published
after it is switched on, and the ruleset then protects `v0.1.0` from the moment it is created.

- **A tag ruleset for `v*`** (repository Settings → Rules → Rulesets; a ruleset that targets the tags `v*`): restrict
  deletions and restrict updates, with no bypass. A version tag then never moves and never disappears. Do not
  restrict creations: the release job creates each tag `vX.Y.Z` with the workflow's token when it publishes the
  Release.
- **Release immutability** (repository Settings → General → Releases → "Enable release immutability"): once a Release
  is published, its tag and assets cannot be changed or deleted. The release job creates a draft, uploads
  `manifest.json` and only then publishes, so it works with the setting on or off.

If a package turns private again (it is a package setting on GitHub, not a repository one), pulling needs a login: see
"A private copy" in [verify.md](verify.md).
