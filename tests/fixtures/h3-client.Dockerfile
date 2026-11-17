# HTTP/3 client for tests/split_smoke.sh: Debian's curl is built with OpenSSL QUIC and nghttp3 (the curl project's
# image and Alpine's curl lack HTTP/3). The script asserts that `curl -V` lists HTTP3.
# debian:trixie-slim
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
