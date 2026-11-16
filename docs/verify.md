# Verifying the images

Every published image is built by the GitHub Actions workflow of this repository, from tested bits, and comes with:

- a **cosign signature** (keyless: made with the workflow's GitHub identity, recorded in the public Sigstore log);
- a **build provenance attestation** (GitHub's signed record of which repository, workflow and commit built it);
- an **SBOM** (the list of packages inside) and buildx provenance, stored in the registry next to the image.

Check them before you trust a tag. Images are `ghcr.io/kickedro/edge-proxy` and `ghcr.io/kickedro/edge-proxy-gen`.
Tags are `latest` and a release tag: `<nginx>-modsec<modsecurity>-crs<crs>-<YYYYMMDD>` for `edge`,
`<docker-gen>-np<first 12 characters of the nginx-proxy commit>-<YYYYMMDD>` for `gen`. A tag can move; a digest cannot, so verify and pin the digest.

You need Docker with buildx, [`jq`](https://jqlang.github.io/jq/), [`cosign`](https://docs.sigstore.dev/cosign/) 3.x (tested
with 3.1.4), and the [GitHub CLI](https://cli.github.com/) (`gh`) 2.49 or newer: older distro packages (for example
Ubuntu's 2.45) have no `gh attestation` command.

## 1. Find the digest of a tag

```sh
EDGE=$(docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy:latest --format '{{json .Manifest}}' | jq -r .digest)
GEN=$(docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy-gen:latest --format '{{json .Manifest}}' | jq -r .digest)
echo "$EDGE" "$GEN"
```

Use another tag in place of `latest` to look up that release. Docker's own `docker pull` prints the same digest.

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
# What is in the image: upstream versions, and the content key CI uses to decide whether to publish
docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy@$EDGE --format '{{json .Image}}' | jq '.config.Labels'
```

- `org.kickedro.versions`: all seven upstream versions of the build (nginx, ModSecurity, the connector, CRS, docker-gen,
  Go, nginx-proxy commit), separated by `;`. Both images carry the same list.
- `org.kickedro.build-key`: one hash over what is inside **both** images (versions, source files, base images, package
  lists, compiled binaries), so it is identical on `edge` and `gen`. The same key means the same content; it is how an
  unchanged daily build is told from a changed one.
- `org.opencontainers.image.{source,revision,version,licenses}`: repository, commit, release tag and licences.
- `maintainer`: on `edge`, inherited from the official nginx base image; expected.

```sh
# The SBOM (SPDX): every Debian package and, for gen, every Go module
docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy@$EDGE --format '{{json .SBOM}}' | jq '.SPDX.packages | length'
docker buildx imagetools inspect ghcr.io/kickedro/edge-proxy@$EDGE --format '{{json .SBOM}}' | jq -r '.SPDX.packages[].name' | sort | head
```

## 5. Pin your deployment by digest

Once verified, refer to the image by digest, so a moved tag cannot change what you run:

```yaml
services:
  nginx-proxy:
    image: ghcr.io/kickedro/edge-proxy@sha256:<the digest you verified>
```

Keep the release tag in a comment (`# 1.31.8-modsec3.0.17-crs4.30.0-20261113`) so you know what you are on. To update,
look up the new digest, repeat steps 2 and 3, and change the line. Images are rebuilt about daily, and published
when their content changes and at least weekly, so plan on updating regularly: that is how you get new security fixes.

## A private copy

If you mirror the images to a private registry, or the packages are not public, log in to the registry first
(`docker login ghcr.io` with a token that has `read:packages`); the commands above then work unchanged. Use a
throwaway `DOCKER_CONFIG` directory if you do not want the credentials stored.
