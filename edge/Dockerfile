# syntax=docker/dockerfile:1

# edge: current nginx mainline + ModSecurity v3 (libmodsecurity + nginx connector) + OWASP CRS 4.
# Build args (from scripts/resolve_versions.py): NGINX_VERSION MODSECURITY_VERSION
# MODSECURITY_NGINX_VERSION CRS_VERSION NGINX_PROXY_REF.
ARG NGINX_VERSION=mainline

# ---------------------------------------------------------------------------------------------------
FROM nginx:${NGINX_VERSION} AS build

ARG NGINX_VERSION
ARG MODSECURITY_VERSION
ARG MODSECURITY_NGINX_VERSION
ARG CRS_VERSION

# Pinned signing keys (full fingerprints). The key files in keys/ are only a convenience: the build
# fails unless the signature was made by a key with exactly these fingerprints.
# nginx: the unexpired developer signing keys listed on https://nginx.org/en/pgp_keys.html (arut, pluknet,
# thresh; the fourth listed key, sb, expired in 2016 and is not trusted).
ARG NGINX_SIGNER_FPRS="43387825DDB1BB97EC36BA5D007C8D7C15D87369 D6786CE303D9A9022998DC6CC8464D549AF75C0A 13C82A63B603576156E30A4EA0EA981B66B0D967"
# OWASP ModSecurity project (libmodsecurity and the nginx connector)
ARG MODSECURITY_SIGNER_FPR=0B2BA1924065B44691202A2AD286E022149F0F6E
# OWASP Core Rule Set project
ARG CRS_SIGNER_FPR=36006F0E0BA167832158821138EEACA1AB8A6E72

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl gnupg \
        libpcre2-dev libssl-dev libxml2-dev libyajl-dev pkg-config zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

COPY keys/ /keys/
COPY verify-signature.sh /usr/local/bin/verify-signature

WORKDIR /src

# -- download and verify -------------------------------------------------------------------------------
# nginx source (for building the connector as a dynamic module): PGP signature from nginx.org.
# libmodsecurity and connector: the release's detached PGP signature (project key) and its sha256 file.
# CRS: the release's detached PGP signature (CRS project key).
RUN set -eux; \
    nginx="nginx-${NGINX_VERSION}.tar.gz"; \
    curl -fsSLO "https://nginx.org/download/$nginx"; \
    curl -fsSLO "https://nginx.org/download/$nginx.asc"; \
    verify-signature "$nginx" "$nginx.asc" /keys/nginx.asc $NGINX_SIGNER_FPRS; \
    gh="https://github.com/owasp-modsecurity"; \
    msc="modsecurity-${MODSECURITY_VERSION}.tar.gz"; \
    for f in "$msc" "$msc.asc" "$msc.sha256"; do curl -fsSLO "$gh/ModSecurity/releases/download/${MODSECURITY_VERSION}/$f"; done; \
    verify-signature "$msc" "$msc.asc" /keys/modsecurity.asc "$MODSECURITY_SIGNER_FPR"; \
    sha256sum -c "$msc.sha256"; \
    conn="ModSecurity-nginx-${MODSECURITY_NGINX_VERSION}.tar.gz"; \
    for f in "$conn" "$conn.asc" "$conn.sha256"; do curl -fsSLO "$gh/ModSecurity-nginx/releases/download/${MODSECURITY_NGINX_VERSION}/$f"; done; \
    verify-signature "$conn" "$conn.asc" /keys/modsecurity.asc "$MODSECURITY_SIGNER_FPR"; \
    sha256sum -c "$conn.sha256"; \
    crs="coreruleset-${CRS_VERSION#v}-minimal.tar.gz"; \
    curl -fsSLO "https://github.com/coreruleset/coreruleset/releases/download/${CRS_VERSION}/$crs"; \
    curl -fsSLO "https://github.com/coreruleset/coreruleset/releases/download/${CRS_VERSION}/$crs.asc"; \
    verify-signature "$crs" "$crs.asc" /keys/coreruleset.asc "$CRS_SIGNER_FPR"; \
    for f in *.tar.gz; do tar -xzf "$f"; done

# -- libmodsecurity ---------------------------------------------------------------------------------------
# Built with only what CRS 4 needs: PCRE2 (regexes), libxml2 (XML bodies), yajl (JSON bodies).
# Disabled: lua (SecRuleScript), curl (SecRemoteRules), maxmind and geoip
# (@geoLookup), lmdb (persistent collections), ssdeep (@fuzzyHash), PCRE1 (end of life), static libs,
# docs and examples. None is used by the CRS.
RUN set -eux; \
    cd "modsecurity-${MODSECURITY_VERSION}"; \
    ./configure --prefix=/usr/local/modsecurity \
        --with-pcre2 --without-pcre --with-libxml --with-yajl \
        --without-lua --without-curl --without-maxmind --without-geoip --without-lmdb --without-ssdeep \
        --disable-static --disable-examples --disable-doxygen-doc --disable-doxygen-html; \
    make -j"$(nproc)"; \
    make install; \
    mkdir -p /stage/usr/local/lib /stage/etc/nginx/modsec; \
    cp -L /usr/local/modsecurity/lib/libmodsecurity.so.3 /stage/usr/local/lib/libmodsecurity.so.3; \
    strip --strip-unneeded /stage/usr/local/lib/libmodsecurity.so.3; \
    cp unicode.mapping /stage/etc/nginx/modsec/unicode.mapping

# -- nginx connector (dynamic module, binary-compatible with the official nginx build) -------------
RUN set -eux; \
    cd "nginx-${NGINX_VERSION}"; \
    MODSECURITY_INC=/usr/local/modsecurity/include MODSECURITY_LIB=/usr/local/modsecurity/lib \
    ./configure --with-compat --with-http_ssl_module --with-http_v2_module \
        --with-cc-opt='-O2 -fstack-protector-strong -fstack-clash-protection -D_FORTIFY_SOURCE=2 -fPIC' \
        --with-ld-opt='-Wl,-z,relro -Wl,-z,now' \
        --add-dynamic-module="../ModSecurity-nginx-${MODSECURITY_NGINX_VERSION}"; \
    make -j"$(nproc)" modules; \
    mkdir -p /stage/usr/lib/nginx/modules; \
    strip --strip-unneeded -o /stage/usr/lib/nginx/modules/ngx_http_modsecurity_module.so objs/ngx_http_modsecurity_module.so

# -- CRS ---------------------------------------------------------------------------------------------------
# The release's own crs-setup.conf.example (active SecDefaultAction lines) stays matched to the CRS version.
RUN set -eux; \
    crs="coreruleset-${CRS_VERSION#v}"; \
    mkdir -p /stage/etc/nginx/modsec/crs; \
    cp -r "$crs/rules" /stage/etc/nginx/modsec/crs/rules; \
    cp "$crs/crs-setup.conf.example" /stage/etc/nginx/modsec/crs/crs-setup.conf; \
    cp "$crs/LICENSE" /stage/etc/nginx/modsec/crs/LICENSE; \
    rm -f /stage/etc/nginx/modsec/crs/rules/*.example

# ---------------------------------------------------------------------------------------------------
FROM nginx:${NGINX_VERSION}

ARG NGINX_PROXY_REF

# Runtime libraries only (no compilers or build tools). libstdc++6, libpcre2-8-0 and zlib come with
# the official image already or as dependencies.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libxml2 libyajl2 libstdc++6; \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /stage/ /
RUN ldconfig

# Same nginx.conf changes as nginx-proxy's Dockerfile.debian at NGINX_PROXY_REF (toplevel.conf.d include,
# worker_connections, worker_rlimit_nofile, directories), so docker-gen's template works unchanged.
RUN echo "\ninclude /etc/nginx/toplevel.conf.d/*.conf;" >> /etc/nginx/nginx.conf \
   && sed -i 's/worker_connections.*;$/worker_connections  10240;/' /etc/nginx/nginx.conf \
   && sed -i -e '/^\}$/{s//\}\nworker_rlimit_nofile 20480;/;:a' -e '$!N;$!ba' -e '}' /etc/nginx/nginx.conf \
   && mkdir -p '/etc/nginx/toplevel.conf.d' \
   && mkdir -p '/etc/nginx/dhparam' \
   && mkdir -p '/etc/nginx/certs' \
   && mkdir -p '/usr/share/nginx/html/errors'
ADD https://raw.githubusercontent.com/nginx-proxy/nginx-proxy/${NGINX_PROXY_REF}/network_internal.conf /etc/nginx/network_internal.conf

# ModSecurity: load the module (main context) and switch it on at http level from an image-owned
# include (not conf.d, which is a shared volume in the split layout).
COPY nginx/modsecurity-http.conf /etc/nginx/modsecurity-http.conf
RUN set -eux; \
    sed -i '1i load_module modules/ngx_http_modsecurity_module.so;' /etc/nginx/nginx.conf; \
    sed -i 's|^\( *\)include /etc/nginx/conf.d/\*.conf;|\1include /etc/nginx/modsecurity-http.conf;\n&|' /etc/nginx/nginx.conf; \
    grep -q '^ *include /etc/nginx/modsecurity-http.conf;' /etc/nginx/nginx.conf; \
    grep -q '^load_module modules/ngx_http_modsecurity_module.so;' /etc/nginx/nginx.conf; \
    chmod 644 /etc/nginx/network_internal.conf

COPY modsecurity/ /etc/nginx/modsec/
# The image's own templates live outside /etc/nginx/templates, which stays free for users' templates
# (official NGINX_ENVSUBST_* mechanism, untouched). 18-modsec-render.sh renders these ones.
COPY templates/ /etc/nginx/modsec/templates/
COPY --chmod=755 docker-entrypoint.d/ /docker-entrypoint.d/

# Working directories: ModSecurity temp/data, rendered settings (the only place written at start; a
# read-only root filesystem needs a tmpfs just there), and the two mount points for site rules.
RUN set -eux; \
    mkdir -p /var/cache/modsecurity/tmp /var/cache/modsecurity/data \
        /etc/nginx/modsec/rendered /etc/nginx/modsec/custom.d /etc/nginx/modsec/after.d; \
    chown -R nginx:nginx /var/cache/modsecurity

# Defaults for the settings (read by 18-modsec-render.sh). The audit log goes to stdout so it is in
# `docker logs` and rotated by Docker; a file path is one variable away.
ENV MODSEC_RULE_ENGINE=On \
    MODSEC_PARANOIA=1 \
    MODSEC_ANOMALY_INBOUND=5 \
    MODSEC_ANOMALY_OUTBOUND=4 \
    MODSEC_REQ_BODY_LIMIT=134217728 \
    MODSEC_AUDIT_LOG=/dev/stdout \
    MODSEC_AUDIT_FORMAT=JSON \
    MODSEC_DENY_STATUS=403
