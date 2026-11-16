## Changes in this repository

### What's Changed
* Add a thing by @someone in #1

### New Contributors
* @someone made their first contribution in #1

**Full Changelog**: https://github.com/KickedRo/edge-proxy/commits/v0.1.0

## Upstream

First versioned release: no earlier version to compare with.

| Component | Version |
| --- | --- |
| nginx | `1.31.8` |
| ModSecurity | `v3.0.17` |
| ModSecurity-nginx connector | `v1.0.4` |
| OWASP CRS | `v4.30.0` |
| docker-gen | `0.17.2` |
| Go (docker-gen build) | `1.27.4` |
| nginx-proxy (commit) | `bff2cddfece8e4f2c6d00b62ba45b8214c4727c5` |

## Packages

### edge

<details>
<summary>Installed (11)</summary>

- `ca-certificates` 20250419+deb13u1
- `gcc-14-base:amd64` 14.2.0-19
- `libc6:amd64` 2.41-12+deb13u4
- `libpcre2-8-0:amd64` 10.46-1~deb13u3
- `libssl3t64:amd64` 3.5.7-1~deb13u3
- `libxml2:amd64` 2.12.7+dfsg+really2.9.14-2.1+deb13u3
- `nginx` 1.31.8-1~trixie
- `nginx-module-njs` 1.31.8+1.0.2-1~trixie
- `openssl` 3.5.7-1~deb13u3
- `tzdata` 2026f-0+deb13u1
- `zlib1g:amd64` 1:1.3.dfsg+really1.3.1-1+deb13u1

</details>

### gen

**Installed (6)**

- `gcc-14-base:amd64` 14.2.0-19
- `libc6:amd64` 2.41-12+deb13u4
- `libssl3t64:amd64` 3.5.7-1~deb13u3
- `openssl` 3.5.7-1~deb13u3
- `tzdata` 2026f-0+deb13u1
- `zlib1g:amd64` 1:1.3.dfsg+really1.3.1-1+deb13u1

#### Go

`go1.27.4`

#### Go modules

**Installed (6)**

- `dario.cat/mergo` v1.0.2
- `example.com/forked` v1.0.1-fixed
- `github.com/BurntSushi/toml` v1.6.0
- `github.com/moby/moby/client` v0.4.1
- `github.com/nginx-proxy/docker-gen` v0.0.0-20260711084634-497e50d07d3a+dirty
- `golang.org/x/sys` v0.49.0

## Images

- **edge**: `ghcr.io/example/edge-proxy:0.1.0`, pinned `ghcr.io/example/edge-proxy@sha256:1111111111111111111111111111111111111111111111111111111111111111`
- **gen**: `ghcr.io/example/edge-proxy-gen:0.1.0`, pinned `ghcr.io/example/edge-proxy-gen@sha256:2222222222222222222222222222222222222222222222222222222222222222`

Verify before you trust them (needs `cosign` 3.x and `gh`; details in [docs/verify.md](https://github.com/KickedRo/edge-proxy/blob/main/docs/verify.md)):

```sh
ID='https://github.com/KickedRo/edge-proxy/.github/workflows/build.yml@refs/heads/main'
ISSUER=https://token.actions.githubusercontent.com

cosign verify ghcr.io/example/edge-proxy@sha256:1111111111111111111111111111111111111111111111111111111111111111 --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER"
cosign verify ghcr.io/example/edge-proxy-gen@sha256:2222222222222222222222222222222222222222222222222222222222222222 --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER"
gh attestation verify oci://ghcr.io/example/edge-proxy@sha256:1111111111111111111111111111111111111111111111111111111111111111 --repo KickedRo/edge-proxy --cert-identity "$ID"
gh attestation verify oci://ghcr.io/example/edge-proxy-gen@sha256:2222222222222222222222222222222222222222222222222222222222222222 --repo KickedRo/edge-proxy --cert-identity "$ID"
```
