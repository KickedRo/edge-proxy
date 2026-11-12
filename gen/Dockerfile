# check=skip=InvalidDefaultArgInFrom
# (DOCKER_GEN_VERSION has no default on purpose: the pinned value comes from build/versions.env.)
# gen: docker-gen plus nginx-proxy's template and entrypoint, a drop-in for nginx-proxy's separate-containers layout.
# Build args come from build/versions.env: DOCKER_GEN_VERSION, NGINX_PROXY_REF.
ARG DOCKER_GEN_VERSION

# ---- fetch nginx-proxy at the pinned commit and prove it is that commit ----------------------------------------
# debian:trixie-slim, pinned by digest (only used to run git; nothing from it reaches the final image).
FROM debian@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS fetch
ARG NGINX_PROXY_REF
RUN test -n "$NGINX_PROXY_REF" && apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git init -q /nginx-proxy && cd /nginx-proxy \
    && git remote add origin https://github.com/nginx-proxy/nginx-proxy.git \
    && git fetch -q --depth 1 origin "$NGINX_PROXY_REF" \
    && git checkout -q FETCH_HEAD \
    && [ "$(git rev-parse HEAD)" = "$NGINX_PROXY_REF" ] \
    || { echo "nginx-proxy checkout does not match NGINX_PROXY_REF=$NGINX_PROXY_REF" >&2; exit 1; }

# ---- final image: same layout as nginx-proxy's Dockerfile.dockergen (Debian flavour) --------------------------
FROM nginxproxy/docker-gen:${DOCKER_GEN_VERSION}-debian
ARG DOCKER_GEN_VERSION
ARG NGINX_PROXY_REF
# DHPARAM_SKIP=true like nginx-proxy's own dockergen image: the default works without a dhparam volume shared
# with the nginx container. Set DHPARAM_SKIP=false and share /etc/nginx/dhparam to get RFC 7919 groups.
ENV NGINX_PROXY_VERSION=${NGINX_PROXY_REF} \
    DOCKER_GEN_VERSION=${DOCKER_GEN_VERSION} \
    DOCKER_HOST=unix:///tmp/docker.sock \
    DHPARAM_SKIP=true \
    NGINX_CONTAINER_LABEL=com.github.nginx-proxy.nginx-proxy.nginx

# Debian security fixes newer than the base image (CI fails on fixable HIGH/CRITICAL findings).
RUN apt-get update \
    && apt-get -y upgrade \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/nginx/conf.d /etc/nginx/vhost.d /etc/nginx/htpasswd /etc/nginx/dhparam /etc/nginx/certs \
        /usr/share/nginx/html/errors

COPY --from=fetch /nginx-proxy/app /nginx-proxy/nginx.tmpl /nginx-proxy/LICENSE /app/
WORKDIR /app/

ENTRYPOINT ["/app/docker-entrypoint.sh"]
# Same arguments as nginx-proxy's Dockerfile.dockergen at NGINX_PROXY_REF. docker-entrypoint.sh replaces
# $NGINX_CONTAINER_LABEL below with the variable's value; the nginx container is found by that label.
CMD ["docker-gen", "-watch", "-wait", "100ms:500ms", "-event-filter", "event=connect", "-event-filter", "event=disconnect", \
     "-notify-filter", "label=$NGINX_CONTAINER_LABEL", "/app/nginx.tmpl", "/etc/nginx/conf.d/default.conf"]
