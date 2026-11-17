"""WebSocket client for tests/streaming_smoke.sh.

Usage: python3 ws_client.py URL --insecure --host NAME [--idle SECONDS]
Connects to URL (wss://) over TLS, with NAME as SNI and Host header; sends `hello` and expects `hello` back, waits
--idle seconds, sends `again` and expects `again`. Prints `handshake <status>`; exits 0 only on success.
Standard library only.
"""
import argparse
import base64
import os
import socket
import ssl
import struct
import sys
import time
from urllib.parse import urlsplit


def send_text(sock, text):
    """Send one masked text frame (client frames must be masked)."""
    payload = text.encode()
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + masked)


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise EOFError("connection closed")
        data += chunk
    return data


def recv_text(sock):
    """Receive one unmasked text frame (short payloads only)."""
    b1, b2 = recv_exact(sock, 2)
    if b1 & 0x0F != 0x1 or b2 & 0x7F >= 126:
        raise ValueError(f"unexpected frame {b1:#x} {b2:#x}")
    return recv_exact(sock, b2 & 0x7F).decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--insecure", action="store_true", help="do not verify the certificate (self-signed)")
    parser.add_argument("--host", required=True, help="name for SNI and the Host header")
    parser.add_argument("--idle", type=float, default=0, help="seconds to wait between the two messages")
    args = parser.parse_args()

    url = urlsplit(args.url)
    ctx = ssl.create_default_context()
    if args.insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((url.hostname, url.port or 443), timeout=30)
    sock = ctx.wrap_socket(raw, server_hostname=args.host)
    path = (url.path or "/") + (f"?{url.query}" if url.query else "")
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {args.host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            break
        head += chunk
    status = head.split(b" ", 2)[1].decode() if head.startswith(b"HTTP/") else "none"
    print(f"handshake {status}", flush=True)
    if status != "101":
        return 1
    sock.settimeout(args.idle + 30)
    for message, wait in (("hello", 0), ("again", args.idle)):
        time.sleep(wait)
        send_text(sock, message)
        got = recv_text(sock)
        if got != message:
            print(f"expected {message!r}, got {got!r}", file=sys.stderr)
            return 1
    print("echo ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
