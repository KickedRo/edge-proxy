## Changes in this repository

None: a rebuild for upstream and security updates.

## Upstream

Changed since 0.1.0:

- nginx: 1.31.7 → 1.31.8
- OWASP CRS: v4.29.0 → v4.30.0

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

**Added (1)**

- `tzdata` 2026f-0+deb13u1

**Removed (1)**

- `libold1:amd64` 1.0-1

**Changed (1)**

- `libc6:amd64` 2.41-12+deb13u3 → 2.41-12+deb13u4

### gen

**Changed (1)**

- `zlib1g:amd64` 1:1.3.dfsg+really1.3.1-1 → 1:1.3.dfsg+really1.3.1-1+deb13u1

#### Go

`go1.27.3` → `go1.27.4`

#### Go modules

**Removed (1)**

- `example.com/removed` v0.1.0

**Changed (1)**

- `github.com/BurntSushi/toml` v1.5.0 → v1.6.0

## Images

- **edge**: `ghcr.io/example/edge-proxy:0.1.1`, pinned `ghcr.io/example/edge-proxy@sha256:1111111111111111111111111111111111111111111111111111111111111111`
- **gen**: `ghcr.io/example/edge-proxy-gen:0.1.1`, pinned `ghcr.io/example/edge-proxy-gen@sha256:2222222222222222222222222222222222222222222222222222222222222222`

Verify before you trust them (needs `cosign` 3.x and `gh`; details in [docs/verify.md](https://github.com/KickedRo/edge-proxy/blob/main/docs/verify.md)):

```sh
ID='https://github.com/KickedRo/edge-proxy/.github/workflows/build.yml@refs/heads/main'
ISSUER=https://token.actions.githubusercontent.com

cosign verify ghcr.io/example/edge-proxy@sha256:1111111111111111111111111111111111111111111111111111111111111111 --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER"
cosign verify ghcr.io/example/edge-proxy-gen@sha256:2222222222222222222222222222222222222222222222222222222222222222 --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER"
gh attestation verify oci://ghcr.io/example/edge-proxy@sha256:1111111111111111111111111111111111111111111111111111111111111111 --repo KickedRo/edge-proxy --cert-identity "$ID"
gh attestation verify oci://ghcr.io/example/edge-proxy-gen@sha256:2222222222222222222222222222222222222222222222222222222222222222 --repo KickedRo/edge-proxy --cert-identity "$ID"
```
