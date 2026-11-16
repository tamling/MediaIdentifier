#!/usr/bin/env python3
"""A model server that answers badly, on purpose.

Everything the review said about the local LLM path was derived by reading.
This is the other half: a real server on 127.0.0.1 that gives the engine, in
turn, each answer a compromised or merely broken model server would give —
and then the engine has to still be alive, still inside the library, and
still have moved nothing it should not have.

The replies, in order, one per request:
  1. a 400-character title            → must not produce a path component
                                         the filesystem refuses
  2. a title of "../../etc"           → must not climb out
  3. a title full of control chars    → must not reach a file name
  4. 8 MB of JSON                     → must not be read into memory whole
                                         and must not hang the run
  5. truncated JSON                   → must be refused, not half-parsed
  6. 200 with an empty body           → must be refused
  7. a Content-Length that lies       → must time out rather than wait for
                                         bytes that never come
  8. a reply after a long delay       → must hit the request timeout
  9. valid, boring                    → proves the server itself works, so
                                         a run that proposes nothing cannot
                                         be blamed on this script

Run with the port as the only argument. Prints the port it bound and then
serves until killed.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPLIES = []


def chat(content):
    return {"choices": [{"message": {"role": "assistant", "content": content}}]}


REPLIES.append(("json", chat(json.dumps(
    {"title": "A" * 400, "year": 2019, "is_series": False}))))
REPLIES.append(("json", chat(json.dumps(
    {"title": "../../etc", "year": 2019, "is_series": False}))))
REPLIES.append(("json", chat(json.dumps(
    {"title": "Film\nmit\tSteuer\x1b[31mzeichen\x7f", "year": 2019,
     "is_series": False}))))
REPLIES.append(("json", chat("x" * 8_000_000)))
REPLIES.append(("raw", b'{"choices": [{"message": {"content": "{\\"title\\": '))
REPLIES.append(("raw", b""))
REPLIES.append(("lying-length", b'{"choices": []}'))
REPLIES.append(("slow", chat(json.dumps(
    {"title": "Spaet", "year": 2019, "is_series": False}))))
REPLIES.append(("json", chat(json.dumps(
    {"title": "Tenet", "year": 2020, "is_series": False}))))


class Hostile(BaseHTTPRequestHandler):
    served = 0

    def log_message(self, *args):
        pass

    def do_GET(self):
        # /v1/models, used by the connection test.
        body = json.dumps({"data": [{"id": "hostile"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

        kind, payload = REPLIES[Hostile.served % len(REPLIES)]
        Hostile.served += 1
        sys.stderr.write(f"hostile-llm: reply {Hostile.served}: {kind}\n")
        sys.stderr.flush()

        if kind == "slow":
            # Longer than the engine's 30-second request timeout.
            time.sleep(45)

        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        if kind == "lying-length":
            # Claims far more than it sends, then stops. The client has to
            # give up on its own.
            self.send_header("Content-Length", str(len(body) + 10_000))
        else:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except BrokenPipeError:
            pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18099
    server = ThreadingHTTPServer(("127.0.0.1", port), Hostile)
    print(f"hostile-llm on 127.0.0.1:{port}, {len(REPLIES)} replies", flush=True)
    server.serve_forever()
