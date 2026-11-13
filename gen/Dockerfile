# check=skip=InvalidDefaultArgInFrom
# (GO_VERSION and DOCKER_GEN_VERSION have no default on purpose: the pinned values come from build/versions.env.)
# gen: docker-gen (built here from its tagged source) plus nginx-proxy's template and entrypoint, a drop-in for
# nginx-proxy's separate-containers layout.
# Build args come from build/versions.env: GO_VERSION, DOCKER_GEN_VERSION, NGINX_PROXY_REF; SECURITY_EPOCH is the date.
ARG GO_VERSION

# ---- build stage: nginx-proxy at the pinned commit, docker-gen from its tag --------------------------------------
# The official golang image has the Go toolchain and git; nothing from it reaches the final image.
FROM golang:${GO_VERSION}-trixie AS build
ARG DOCKER_GEN_VERSION
ARG NGINX_PROXY_REF
# Never download another toolchain; -mod=mod lets `go get` rewrite go.mod and go.sum.
ENV GOTOOLCHAIN=local GOFLAGS=-mod=mod CGO_ENABLED=0

RUN test -n "$NGINX_PROXY_REF" && test -n "$DOCKER_GEN_VERSION"
RUN git init -q /nginx-proxy && cd /nginx-proxy \
    && git remote add origin https://github.com/nginx-proxy/nginx-proxy.git \
    && git fetch -q --depth 1 origin "$NGINX_PROXY_REF" \
    && git checkout -q FETCH_HEAD \
    && [ "$(git rev-parse HEAD)" = "$NGINX_PROXY_REF" ] \
    || { echo "nginx-proxy checkout does not match NGINX_PROXY_REF=$NGINX_PROXY_REF" >&2; exit 1; }

# docker-gen at its release tag (tags have no "v").
RUN set -eux; \
    git clone -q --depth 1 --branch "$DOCKER_GEN_VERSION" https://github.com/nginx-proxy/docker-gen.git /src; \
    echo "docker-gen $DOCKER_GEN_VERSION is commit $(git -C /src rev-parse HEAD)"

# Vulnerability-driven dependency upgrades, nothing else: govulncheck (pinned; Go's checksum database verifies
# the download) scans docker-gen's go.mod and packages against the Go vulnerability database (-scan package: module
# mode refuses a module root without Go files, which docker-gen's is), and every module finding that
# has a fixed version gets exactly that version (the lowest one that fixes all its findings, never a new major).
# Findings without a fix, and the Go standard library (which follows GO_VERSION), are left to the Trivy gate in CI.
# Then docker-gen's own tests must pass and the binary is built. SECURITY_EPOCH (the UTC date, from CI) is only
# declared here so this step re-runs daily with the then-current vulnerability database; every layer before it
# stays cached.
ARG SECURITY_EPOCH
RUN set -eux; \
    echo "security epoch $SECURITY_EPOCH"; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends jq; \
    rm -rf /var/lib/apt/lists/*; \
    go install golang.org/x/vuln/cmd/govulncheck@v1.9.0; \
    cd /src; \
    govulncheck -scan package -format json ./... > /tmp/vulns.json; \
    jq -r 'select(.finding) | .finding | select((.fixed_version // "") != "") | .trace[0] \
           | select(.module != "stdlib" and .module != "toolchain") | .module' /tmp/vulns.json | sort -u > /tmp/modules; \
    echo "--- modules with fixable vulnerabilities: $(wc -l < /tmp/modules)"; \
    while read -r mod; do \
        fixed="$(jq -r --arg m "$mod" 'select(.finding) | .finding | select(.trace[0].module == $m and (.fixed_version // "") != "") \
                 | .fixed_version' /tmp/vulns.json | sort -V | tail -n 1)"; \
        echo "upgrade $mod to $fixed"; \
        go get "$mod@$fixed"; \
    done < /tmp/modules; \
    go mod tidy; \
    go test ./...; \
    go build -trimpath -ldflags "-X main.buildVersion=${DOCKER_GEN_VERSION}" -o /docker-gen ./cmd/docker-gen; \
    /docker-gen -version; \
    echo "--- docker-gen build info"; \
    go version -m /docker-gen

# ---- final image: same layout as nginx-proxy's Dockerfile.dockergen (Debian flavour) --------------------------
# What upstream's docker-gen Debian image provides: debian slim, openssl, the binary in /usr/local/bin, the license.
FROM debian:trixie-slim
ARG DOCKER_GEN_VERSION
ARG NGINX_PROXY_REF
# DHPARAM_SKIP=true like nginx-proxy's own dockergen image: the default works without a dhparam volume shared
# with the nginx container. Set DHPARAM_SKIP=false and share /etc/nginx/dhparam to get RFC 7919 groups.
ENV NGINX_PROXY_VERSION=${NGINX_PROXY_REF} \
    DOCKER_GEN_VERSION=${DOCKER_GEN_VERSION} \
    DOCKER_HOST=unix:///tmp/docker.sock \
    DHPARAM_SKIP=true \
    NGINX_CONTAINER_LABEL=com.github.nginx-proxy.nginx-proxy.nginx

# Debian security fixes newer than the base image (CI fails on fixable HIGH/CRITICAL findings), and openssl
# (needed by the entrypoint for DH parameters). SECURITY_EPOCH (the UTC date, from CI) is only declared so this
# layer is rebuilt daily instead of being served from the build cache forever.
ARG SECURITY_EPOCH
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get -y upgrade \
    && apt-get install -y -q --no-install-recommends openssl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/nginx/conf.d /etc/nginx/vhost.d /etc/nginx/htpasswd /etc/nginx/dhparam /etc/nginx/certs \
        /usr/share/nginx/html/errors

COPY --from=build /docker-gen /usr/local/bin/docker-gen
COPY --from=build /src/LICENSE /usr/local/share/doc/docker-gen/
COPY --from=build /nginx-proxy/app /nginx-proxy/nginx.tmpl /nginx-proxy/LICENSE /app/
WORKDIR /app/

ENTRYPOINT ["/app/docker-entrypoint.sh"]
# Same arguments as nginx-proxy's Dockerfile.dockergen at NGINX_PROXY_REF. docker-entrypoint.sh replaces
# $NGINX_CONTAINER_LABEL below with the variable's value; the nginx container is found by that label.
CMD ["docker-gen", "-watch", "-wait", "100ms:500ms", "-event-filter", "event=connect", "-event-filter", "event=disconnect", \
     "-notify-filter", "label=$NGINX_CONTAINER_LABEL", "/app/nginx.tmpl", "/etc/nginx/conf.d/default.conf"]
