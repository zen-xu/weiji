"""Synthetic loopback-only MCP process fixture, using the Python standard library."""
import http.client
import json
import socket
import subprocess
import time


class HTTPClient:
    def __init__(self, binary, data_dir, gui=False):
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            self.port = reserve.getsockname()[1]
        self.url = f"http://127.0.0.1:{self.port}/mcp"
        if gui:
            data_dir.mkdir()
            (data_dir / "preferences.json").write_text(json.dumps({
                "collectOnLaunch": False, "pollSeconds": 2, "mcpPort": self.port,
            }))
            args = ["--demo"]
        else:
            args = ["mcp-http", "--port", str(self.port)]
        self.process = subprocess.Popen(
            [str(binary), *args, "--data-dir", str(data_dir)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            for _ in range(100):
                if self.process.poll() is not None:
                    raise AssertionError("HTTP service exited: " + self.process.stderr.read())
                try:
                    code, _, _ = self.request(method="GET")
                    if code == 405:
                        break
                except OSError:
                    pass
                time.sleep(0.05)
            else:
                raise AssertionError("HTTP listener did not start")
        except BaseException:
            self.close()
            raise

    def request(self, value=None, method="POST", path="/mcp", headers=None):
        fields = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json",
                  "MCP-Protocol-Version": "2025-06-18"}
        fields.update(headers or {})
        body = json.dumps(value, ensure_ascii=False).encode() if value is not None else None
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=fields)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
