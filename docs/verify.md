# Verifying the images

Every published image is built by the GitHub Actions workflow of this repository, from tested bits, and comes with:

- a **cosign signature** (keyless: made with the workflow's GitHub identity, recorded in the public Sigstore log);
- a **build provenance attestation** (GitHub's signed record of which repository, workflow and commit built it);
- an **SBOM** (the list of packages inside) and buildx provenance, stored in the registry next to the image;
- a **GitHub Release** for its version, with release notes and a `manifest.json` of what is inside
  ([below](#release-notes-and-manifestjson)).

Check them before you trust a tag. Images are `ghcr.io/kickedro/edge-proxy` and `ghcr.io/kickedro/edge-proxy-gen`,
for `linux/amd64` only.

You need Docker with buildx, [`jq`](https://jqlang.github.io/jq/), [`cosign`](https://docs.sigstore.dev/cosign/) 3.x (tested
with 3.1.4), and the [GitHub CLI](https://cli.github.com/) (`gh`) 2.49 or newer: older distro packages (for example
Ubuntu's 2.45) have no `gh attestation` command.

## Tags and versions

Both images share one version, `MAJOR.MINOR.PATCH` (SemVer): `edge-proxy:0.1.3` and `edge-proxy-gen:0.1.3` were built,
tested and published together. Each image has three kinds of tag:

| Tag | Example | Points to |
|---|---|---|
| `X.Y.Z` | `0.1.3` | One image. It never moves, and a version number is never used twice. |
| `X.Y` | `0.1` | The newest patch of that line. It moves with every patch release of the line. |
| `latest` | `latest` | The newest version. It moves with every release. |

`MAJOR.MINOR` changes when the project adds a feature or changes a default (the [changelog](../CHANGELOG.md) says what
changed). `PATCH` goes up whenever the build pipeline publishes changed content: a new upstream release, a Debian
security update, or one of the project's fixes. An image whose content did not change is not published again.

Tags from before 0.1.0 keep their date-based names, and no new ones of that kind are made:
`<nginx>-modsec<modsecurity>-crs<crs>-<YYYYMMDD>` for `edge`, `<docker-gen>-np<first 12 characters of the nginx-proxy
commit>-<YYYYMMDD>` for `gen` (UTC date; a second publish on the same day got `.2` after the date). They never moved
either.

Even a tag that never moves is only a name: what the signature covers is the digest. Verify the digest, and pin it.

## 1. Find the digest of a tag

```sh
EDGE=$(docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy:latest --format '{{json .Manifest}}' | jq -r .digest)
GEN=$(docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy-gen:latest --format '{{json .Manifest}}' | jq -r .digest)
echo "$EDGE" "$GEN"
```

Use a version tag such as `0.1.0` in place of `latest` to look up that version. Docker's own `docker pull` prints the
same digest, and the version's Release lists both.

## 2. Verify the signature

```sh
ID='https://github.com/KickedRo/edge-proxy/.github/workflows/build.yml@refs/heads/main'
ISSUER=https://token.actions.githubusercontent.com

cosign verify ghcr.io/kickedro/edge-proxy@$EDGE     --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER"
cosign verify ghcr.io/kickedro/edge-proxy-gen@$GEN  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER"
```

Success means: the image was signed by the `build.yml` workflow of this repository on `main`. The command exits
non-zero for anything else, and prints the JSON of the signature on success.

## 3. Verify the provenance attestation

```sh
gh attestation verify oci://ghcr.io/kickedro/edge-proxy@$EDGE    --repo KickedRo/edge-proxy --cert-identity "$ID"
gh attestation verify oci://ghcr.io/kickedro/edge-proxy-gen@$GEN --repo KickedRo/edge-proxy --cert-identity "$ID"
```

This enforces the same workflow and branch as step 2 (`$ID` is defined there). Unlike `cosign verify`, this step needs
you to be logged in to GitHub (`gh auth login`), even though the images are public. Expected: `Verification succeeded!`
and a row naming this repository and `.github/workflows/build.yml@refs/heads/main`.

## 4. Read the labels and the SBOM

```sh
# What is in the image: its version, upstream versions, and the content key CI uses to decide whether to publish
docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy@$EDGE --format '{{json .Image}}' | jq '.config.Labels'
```

- `org.opencontainers.image.version`: the version, `X.Y.Z`, the same on both images. Images from before 0.1.0 hold
  their date-based tag here.
- `org.opencontainers.image.revision`: the commit that was built. The git tag `vX.Y.Z` of the version's Release is on
  that commit.
- `org.opencontainers.image.{source,licenses}`: the repository and the licences.
- `org.kickedro.versions`: all seven upstream versions of the build (nginx, ModSecurity, the connector, CRS, docker-gen,
  Go, nginx-proxy commit), separated by `;`. Both images carry the same list.
- `org.kickedro.build-key`: one hash over what is inside **both** images (versions, source files, base images, package
  lists, compiled binaries), so it is identical on `edge` and `gen`. The same key means the same content; it is how an
  unchanged daily build is told from a changed one.
- `maintainer`: on `edge`, inherited from the official nginx base image; expected.

```sh
# The SBOM (SPDX): every Debian package and, for gen, every Go module
docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy@$EDGE --format '{{json .SBOM}}' | jq '.SPDX.packages | length'
docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy@$EDGE --format '{{json .SBOM}}' | jq -r '.SPDX.packages[].name' | sort | head
```

## 5. Pin your deployment by version and digest

Once verified, refer to the image by version and digest:

```yaml
services:
  nginx-proxy:
    image: ghcr.io/kickedro/edge-proxy:0.1.0@sha256:<the digest you verified>
  nginx-proxy-gen:
    image: ghcr.io/kickedro/edge-proxy-gen:0.1.0@sha256:<the digest you verified>
```

Docker pulls by the digest when both are given, so a tag cannot change what you run; the version is there so you
know what you are on. Use the same version for both images.

To update: read the new version's release notes, look up its digests, repeat steps 2 and 3, and change both lines.
Images are rebuilt daily and published as a new patch whenever their content changes, so plan on updating
regularly: that is how you get new security fixes. To be told about new versions, watch the repository's releases
on GitHub (**Watch** → **Custom** → **Releases**).

If you would rather take every patch of a line without editing the file, refer to the line tag (`edge-proxy:0.1`):
it moves to each new patch of 0.1, but never to 0.2. You then trust the tag at each pull, so verify what you run
from time to time.

## Release notes and `manifest.json`

Every version has a GitHub Release `vX.Y.Z` on the [Releases](https://github.com/KickedRo/edge-proxy/releases) page,
created by the same workflow right after the images are published. Its notes have these parts:

1. For a minor or major release (`X.Y.0`): the version's **Upgrading** note from the [changelog](../CHANGELOG.md),
   when it has one, and a link to its section there.
2. **Changes in this repository**: the pull requests merged since the previous release, as GitHub lists them.
3. **Upstream**: the upstream versions that changed since the previous release (old → new), and a table of all of
   them.
4. **Packages**: per image, the Debian packages that were added, removed or changed version, and for `gen` the Go
   version and the Go modules that changed. Long lists are folded, and when they are too long for a Release (a
   large Debian update), a pointer to `manifest.json` takes their place.
5. **Images**: both images by version and digest, with the `cosign verify` and `gh attestation verify` commands of
   steps 2 and 3 filled in.

The first release, `v0.1.0`, has no earlier version to compare with, so its lists are complete instead.

Each Release has one asset, `manifest.json`: the version, the commit, the build key, both image references with their
digests, the upstream versions, the Debian package list of each image, and docker-gen's Go version and modules.

```sh
curl -fsSLO https://github.com/KickedRo/edge-proxy/releases/download/v0.1.0/manifest.json
jq -r '.version, .commit, .images.edge.digest, .images.gen.digest' manifest.json
```

The digests in it must match what you verified in steps 2 and 3. The manifest is a record of what is inside, not a
signature: it is attached by the workflow, and the image signatures are what you verify.

## A private copy

If you mirror the images to a private registry, or the packages are not public, log in to the registry first
(`docker login ghcr.io` with a token that has `read:packages`); the commands above then work unchanged. Use a
throwaway `DOCKER_CONFIG` directory if you do not want the credentials stored.
