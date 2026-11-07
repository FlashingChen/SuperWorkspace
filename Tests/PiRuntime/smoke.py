"""Exercise the packaged SDK against a local Chat Completions fixture."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading


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
            for tools in (False, True):
                request = {"baseURL": f"{scheme}://localhost:{server.server_port}/v1", "model": "fixture-model",
                           "key": "fixture-key", "system": "Integration check.", "prompt": "Fixture", "tools": tools}
                reply = subprocess.run([node, runtime / "run.mjs"], input=json.dumps(request), text=True,
                                       capture_output=True, timeout=25, cwd=temp, env=env)
                assert reply.returncode == 0, reply.stderr
                assert reply.stdout.strip() == "OK", reply.stdout
            assert not Provider.calls[0].get("tools")
            assert version in json.dumps(Provider.calls[-1]["messages"][-1])
            assert (Path(temp) / "fixture.txt").read_text() == "ready"
        finally:
            server.shutdown()
    print("Packaged Pi completed a text request and a tool call with bundled Node and npm.")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
