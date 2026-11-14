"""Exercise the packaged SDK against a local Chat Completions fixture."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import base64
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import zlib


class Provider(BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.calls.append(request)
        if (self.path != "/v1/chat/completions" or request["model"] != "fixture-model"
                or self.headers.get("Authorization") != "Bearer fixture-key"):
            self.send_error(400)
            return

        if request.get("tools") and request["messages"][-1]["role"] != "tool":
            command = "node --version && npm --version && ! env | grep -Fq 'fixture-key' && printf ready > fixture.txt"
            delta = {"tool_calls": [{"index": 0, "id": "fixture", "type": "function",
                                     "function": {"name": "bash", "arguments": json.dumps({"command": command})}}]}
            reason = "tool_calls"
        else:
            delta, reason = {"content": "OK"}, "stop"

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for change, finish in [({"role": "assistant"}, None), (delta, None), ({}, reason)]:
            chunk = {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
                     "choices": [{"index": 0, "delta": change, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *args):
        pass


def test_image():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)
    pixels = (b"\x00" + b"\x00\x00\xff" * 16) * 16
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
    return base64.b64encode(png).decode()


def progress_events(stderr):
    events = []
    for line in stderr.splitlines():
        if line.startswith("SW_PROGRESS "):
            events.append(json.loads(line[len("SW_PROGRESS "):]))
    return events


def run_fixture(node, runtime, request, temp, env):
    return subprocess.run([node, runtime / "run.mjs"], input=json.dumps(request), text=True,
                          capture_output=True, timeout=25, cwd=temp, env=env)


def main(runtime):
    runtime = runtime.resolve()
    node = runtime / "node" / "bin" / "node"
    env = {key: os.environ[key] for key in ("HOME", "TMPDIR") if key in os.environ}
    env["PATH"] = f"{node.parent}:/usr/bin:/bin"
    version = subprocess.check_output([node, "--version"], text=True).strip()
    with HTTPServer(("localhost", 0), Provider) as server, tempfile.TemporaryDirectory() as temp:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        scheme = "http"
        try:
            pixel = test_image()
            for tools, images in [(False, False), (False, True), (True, False)]:
                request = {"baseURL": f"{scheme}://localhost:{server.server_port}/v1", "model": "fixture-model",
                           "key": "fixture-key", "system": "Integration check.", "prompt": "Fixture", "tools": tools,
                           "images": images, "attachments": [{"type": "image", "mimeType": "image/png", "data": pixel}] if images else []}
                reply = run_fixture(node, runtime, request, temp, env)
                assert reply.returncode == 0, reply.stderr
                assert reply.stdout.strip() == "OK", reply.stdout
                events = progress_events(reply.stderr)
                assert any(event["type"] == "start" for event in events), reply.stderr
                if tools:
                    assert any(event["type"] == "turn" for event in events), reply.stderr
                    assert any(event["type"] == "tool" and event["name"] == "bash" for event in events), reply.stderr
                    assert any(event["type"] == "done" for event in events), reply.stderr
            assert not Provider.calls[0].get("tools")
            assert not Provider.calls[1].get("tools")
            parts = Provider.calls[1]["messages"][-1]["content"]
            image_url = next(part["image_url"]["url"] for part in parts if part["type"] == "image_url")
            assert image_url.startswith("data:image/png;base64,")
            assert base64.b64decode(image_url.split(",", 1)[1]) == base64.b64decode(pixel)
            assert version in json.dumps(Provider.calls[-1]["messages"][-1])
            assert (Path(temp) / "fixture.txt").read_text() == "ready"
            budget_request = {"baseURL": f"{scheme}://localhost:{server.server_port}/v1", "model": "fixture-model",
                              "key": "fixture-key", "system": "Integration check.", "prompt": "Fixture", "tools": True,
                              "images": False, "attachments": [], "budgetToolCalls": 0}
            reply = run_fixture(node, runtime, budget_request, temp, env)
            assert reply.returncode != 0, (reply.returncode, reply.stdout)
            assert not reply.stdout.strip(), reply.stdout
            budget_events = [event for event in progress_events(reply.stderr)
                             if event["type"] == "budget" and event["reason"] == "toolCalls"]
            assert budget_events, reply.stderr
        finally:
            server.shutdown()
    print("Packaged Pi completed text and image requests and a tool call with bundled Node and npm; "
          "progress events and the tool-call budget abort behave.")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
