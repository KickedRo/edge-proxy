# edge-proxy

Two container images for the nginx-proxy "separate containers" layout:

- `edge`: current nginx mainline + ModSecurity v3 + OWASP Core Rule Set 4,
  hardened by default, every setting one environment variable.
- `gen`: docker-gen plus nginx-proxy's template, pinned and rebuilt automatically.

Status: work in progress, private. Not ready for use.

Licence: MIT, see LICENSE and NOTICE.
