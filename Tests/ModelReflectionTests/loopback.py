#!/usr/bin/env python3
"""Active fake model credential → real loopback → native socket consumer.

Only a locally generated in-memory canary is sent. This is not a provider, VM,
CLI or GUI acceptance test. Model's production fixed endpoint is unchanged; the
Swift test's URLProtocol forwards that request to this owned HTTP fixture.
"""
import argparse
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import threading
import time

MODES = (
    "plain", "escaped", "adjacent", "tool", "tool-escaped", "sse-split",
    "sse-escaped", "sse-tool-escaped", "error", "ordinary", "ordinary-sse",
    "ordinary-tool", "prefix-sse",
)


def encoded(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


def events(texts, *, tool=False):
    result = [{"type": "message_start", "message": {
        "id": "msg_loopback", "type": "message", "role": "assistant",
        "model": "deepseek-flash", "content": [], "usage": {"input_tokens": 1, "output_tokens": 0},
    }}]
    result.append({"type": "content_block_start", "index": 0, "content_block":
        {"type": "tool_use", "id": "tool_1", "name": "record", "input": {}} if tool else {"type": "text", "text": ""}})
    for text in texts:
        result.append({"type": "content_block_delta", "index": 0, "delta":
            {"type": "input_json_delta", "partial_json": text} if tool else {"type": "text_delta", "text": text}})
    result.extend([
        {"type": "content_block_stop", "index": 0},
        {"type": "message_delta", "delta": {"stop_reason": "tool_use" if tool else "end_turn"}, "usage": {"output_tokens": 1}},
        {"type": "message_stop"},
    ])
    return [b"data: " + encoded(event) + b"\n\n" for event in result]


def response(mode, canary):
    escaped = "".join(f"\\u{ord(c):04x}" for c in canary)
    if mode == "error":
        return 503, False, [encoded({"error": {"message": canary}})]
    if mode == "sse-split":
        middle = len(canary) // 2
        return 200, True, events(["ordinary ", canary[:middle], canary[middle:]])
    if mode == "sse-escaped":
        result = events(["ESCAPED_CANARY"])
        return 200, True, [item.replace(b"ESCAPED_CANARY", escaped.encode()) for item in result]
    if mode == "sse-tool-escaped":
        value = '{"value":"' + escaped + '"}'
        middle = len(value) // 2
        return 200, True, events([value[:middle], value[middle:]], tool=True)
    if mode == "ordinary-sse":
        return 200, True, events(["ordinary ", "loopback"])
    if mode == "prefix-sse":
        return 200, True, events(["ordinary ", canary[:12]])
    if mode in ("tool", "tool-escaped", "ordinary-tool"):
        value = "ordinary loopback" if mode == "ordinary-tool" else ("ESCAPED_CANARY" if mode == "tool-escaped" else canary)
        content = [{"type": "tool_use", "id": "tool_1", "name": "record", "input": {"value": value}}]
    elif mode == "adjacent":
        middle = len(canary) // 2
        content = [{"type": "text", "text": part} for part in [canary[:middle], canary[middle:]]]
    else:
        content = [{"type": "text", "text": "ordinary loopback" if mode == "ordinary" else ("ESCAPED_CANARY" if mode == "escaped" else canary)}]
    body = encoded({"id": "msg_loopback", "type": "message", "role": "assistant", "model": "deepseek-flash", "content": content,
                    "stop_reason": "tool_use" if mode in ("tool", "tool-escaped", "ordinary-tool") else "end_turn",
                    "usage": {"input_tokens": 1, "output_tokens": 1}})
    return 200, False, [body.replace(b"ESCAPED_CANARY", escaped.encode())]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[2] / ".build/debug/ExecutionBoundaryChecks")
    args = parser.parse_args()
    counts = Counter()
    failures = []
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                if self.path != "/reflection" or self.headers.get("Transfer-Encoding"):
                    raise ValueError("path/framing")
                length = int(self.headers["Content-Length"])
                if not 0 < length <= 65536:
                    raise ValueError("length")
                body = json.loads(self.rfile.read(length))
                mode = body["messages"][0]["content"]
                if isinstance(mode, list):
                    mode = mode[0]["text"]
                canary = self.headers.get("x-api-key", "")
                if mode not in MODES or not canary.startswith("sk-native-canary-") or len(canary) != 53:
                    raise ValueError("fixture identity")
                with lock:
                    counts[mode] += 1
                status, streaming, chunks = response(mode, canary)
                self.send_response(status)
                self.send_header("Content-Type", "text/event-stream" if streaming else "application/json")
                self.send_header("Content-Length", str(sum(map(len, chunks))))
                self.send_header("Connection", "close")
                self.end_headers()
                for chunk in chunks:
                    # Actual HTTP writes preserve SSE cross-event delay and also
                    # split JSON bodies at transport boundaries.
                    for offset in range(0, len(chunk), 47):
                        self.wfile.write(chunk[offset:offset + 47])
                        self.wfile.flush()
                    if streaming:
                        time.sleep(0.01)
            except (BrokenPipeError, ConnectionResetError):
                # Expected when the model transport rejects reflection early.
                pass
            except Exception:
                with lock:
                    failures.append("fixture request/response failure")
                self.close_connection = True

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        child = subprocess.run([str(args.binary), "--model-reflection-loopback"],
            input=json.dumps({"port": server.server_address[1]}) + "\n", text=True,
            capture_output=True, timeout=90)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    # Do not print arbitrary child output: only static case labels and numeric
    # output metrics are part of the evidence contract.
    import re
    accepted = []
    for line in child.stdout.splitlines():
        if re.fullmatch(r"PASS native-reflection [a-z-]+ peer_bytes=\d+ secret_occurrences=0 reads=1 resumes=1 audit=(unknown|completed)", line):
            accepted.append(line)
            print(line)
        elif line.startswith("FAIL native-reflection"):
            print("FAIL native-reflection child assertion")
    expected = Counter({mode: 1 for mode in MODES})
    if child.returncode or failures or counts != expected or len(accepted) != len(MODES):
        print(f"FAIL native-reflection-loopback child_exit={child.returncode} hits={sum(counts.values())} cases={len(accepted)} fixture_errors={len(failures)}")
        return 1
    print(f"PASS native-reflection-loopback actual_http_hits={sum(counts.values())} cases={len(MODES)} secret_occurrences=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
