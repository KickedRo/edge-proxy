"""Backend for tests/streaming_smoke.sh: routes that keep a connection open for a long time.

Standard library only. Usage: python3 stream_backend.py [--port 8000]
"""
import argparse
import base64
import hashlib
import struct
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"  # RFC 6455 section 1.3
PIECES = 5  # pieces of /sse and /html, one per second
POLL_SECONDS = 25


def read_exact(rfile, n):
    """Read exactly n bytes or raise EOFError."""
    data = rfile.read(n)
    if len(data) != n:
        raise EOFError
    return data


def read_frame(rfile):
    """Read one client frame (always masked): returns (opcode, payload)."""
    b1, b2 = read_exact(rfile, 2)
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", read_exact(rfile, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(rfile, 8))[0]
    mask = read_exact(rfile, 4) if b2 & 0x80 else b"\0\0\0\0"
    payload = bytearray(read_exact(rfile, length))
    for i in range(length):
        payload[i] ^= mask[i % 4]
    return b1 & 0x0F, bytes(payload)


def frame(opcode, payload=b""):
    """Build one unmasked server frame (payloads here are short)."""
    assert len(payload) < 126
    return bytes([0x80 | opcode, len(payload)]) + payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        route = self.path.split("?", 1)[0]
        if route == "/ws":
            self.ws()
        elif route == "/sse":
            self.sse()
        elif route == "/poll":
            self.poll()
        elif route == "/html":
            self.html()
        else:
            self.reply(404, b"not found\n")

    def reply(self, status, body):
        """A plain, complete answer."""
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def ws(self):
        """WebSocket echo: text frames come back unchanged, pings are answered, close ends it."""
        key = self.headers.get("Sec-WebSocket-Key")
        if "websocket" not in self.headers.get("Upgrade", "").lower() or not key:
            self.reply(400, b"not a WebSocket handshake\n")
            return
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True
        try:
            while True:
                opcode, payload = read_frame(self.rfile)
                if opcode == 0x1:  # text
                    self.wfile.write(frame(0x1, payload))
                elif opcode == 0x9:  # ping
                    self.wfile.write(frame(0xA, payload))
                elif opcode == 0x8:  # close
                    self.wfile.write(frame(0x8, payload[:2]))
                    return
        except (EOFError, OSError):
            return

    def stream_headers(self, content_type, extra=()):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache")
        for name, value in extra:
            self.send_header(name, value)
        self.end_headers()

    def sse(self):
        """Server-sent events: one `data: <n>` event per second, PIECES of them. X-Accel-Buffering tells nginx not to
        buffer; the connection closes at the end (no Content-Length, so the body ends with it)."""
        self.stream_headers("text/event-stream", [("X-Accel-Buffering", "no"), ("Connection", "close")])
        self.close_connection = True
        try:
            for n in range(1, PIECES + 1):
                self.wfile.write(f"data: {n}\n\n".encode())
                self.wfile.flush()
                time.sleep(1)
        except OSError:
            pass

    def poll(self):
        """Long poll: answers `200 polled` after POLL_SECONDS."""
        time.sleep(POLL_SECONDS)
        self.reply(200, b"polled")

    def html(self):
        """Chunked text/html, one chunk per second, PIECES of them: a type the WAF inspects in responses. No
        X-Accel-Buffering, so this shows what the WAF itself does to a streamed response."""
        self.stream_headers("text/html", [("Transfer-Encoding", "chunked")])
        try:
            for n in range(1, PIECES + 1):
                data = f"<p>chunk {n}</p>\n".encode()
                self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                self.wfile.flush()
                time.sleep(1)
            self.wfile.write(b"0\r\n\r\n")
        except OSError:
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
