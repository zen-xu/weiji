#!/usr/bin/env python3
"""Real TCP framing, isolation, concurrency and lifecycle checks; no real archive."""
import concurrent.futures
import json
import pathlib
import socket
import subprocess
import sys
import tempfile

from mcp_http_client import HTTPClient

binary = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="wechat-http-test-") as directory:
    root = pathlib.Path(directory)
    client = HTTPClient(binary, root / "must-not-exist")
    try:
        initialize = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "synthetic-http-client", "version": "1"},
        }}
        code, headers, body = client.request(initialize)
        assert code == 200 and json.loads(body)["result"]["protocolVersion"] == "2025-06-18"
        assert "Mcp-Session-Id" not in headers and headers["Cache-Control"] == "no-store"
        code, _, body = client.request({"jsonrpc": "2.0", "method": "notifications/initialized"})
        assert code == 202 and body == b""
        ping = {"jsonrpc": "2.0", "id": 2, "method": "ping"}
        code, _, body = client.request({"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
        assert code == 200 and len(json.loads(body)["result"]["tools"]) == 16
        code, _, body = client.request({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                       "params": {"name": "wechat_status", "arguments": {}}})
        assert code == 200 and json.loads(body)["result"]["structuredContent"]["archive_available"] is False
        assert not (root / "must-not-exist").exists()
        for fields, expected in [({"Origin": "https://example.invalid"}, 403),
                                 ({"Origin": "null"}, 403),
                                 ({"Host": "rebind.invalid"}, 403),
                                 ({"Content-Type": "text/plain"}, 415),
                                 ({"Accept": "text/event-stream"}, 406),
                                 ({"MCP-Protocol-Version": "2025-11-25"}, 400)]:
            assert client.request(ping, headers=fields)[0] == expected
        assert client.request(method="GET")[0] == 405
        assert client.request(method="DELETE")[0] == 405
        assert client.request(ping, path="/other")[0] == 404
        def raw_request(chunks):
            with socket.create_connection(("127.0.0.1", client.port), timeout=5) as connection:
                for chunk in chunks:
                    connection.sendall(chunk)
                chunks = []
                while data := connection.recv(65536):
                    chunks.append(data)
                return b"".join(chunks)
        body = json.dumps(ping).encode()
        head = (f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{client.port}\r\n"
                f"Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n"
                f"Content-Length: {len(body)}\r\n\r\n").encode()
        response = raw_request([head[:7], head[7:-1], head[-1:] + body[:4], body[4:]])
        assert response.startswith(b"HTTP/1.1 200") and json.loads(response.split(b"\r\n\r\n")[1])["id"] == 2
        for wire, code in [
            (b"POST /mcp HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n", 400),
            (b"POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
            (b"POST /mcp HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n", 413),
            (b"GET /mcp HTTP/1.1\r\nX-Large: " + b"x" * 17000, 431),
        ]:
            assert raw_request([wire]).startswith(f"HTTP/1.1 {code}".encode())
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            assert all(code == 200 for code in pool.map(lambda _: client.request(ping)[0], range(40)))
        conflict = subprocess.run([str(binary), "mcp-http", "--port", str(client.port),
                                   "--data-dir", str(root / "other")], capture_output=True, timeout=5)
        assert conflict.returncode != 0 and b"MCP HTTP:" in conflict.stderr
        assert client.request(ping)[0] == 200, "Port conflict must not stop the existing service"
        for port in ["0", "65536", "invalid"]:
            result = subprocess.run([str(binary), "mcp-http", "--port", port], capture_output=True, timeout=5)
            assert result.returncode != 0
    finally:
        client.close()
    assert client.process.stdout.read() == ""
    assert client.process.stderr.read() == f"MCP listening at {client.url}\n"
    with socket.socket() as connection:
        assert connection.connect_ex(("127.0.0.1", client.port)) != 0
    # The same port can be reused after process termination.
    restarted = subprocess.Popen([str(binary), "mcp-http", "--port", str(client.port),
                                  "--data-dir", str(root / "still-absent")], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
    try:
        assert restarted.stderr.readline() == f"MCP listening at {client.url}\n"
        assert client.request(ping)[0] == 200
    finally:
        restarted.terminate()
        restarted.wait(timeout=5)
    assert not (root / "still-absent").exists()
    if "--gui" in sys.argv[2:]:
        gui = HTTPClient(binary, root / "synthetic-gui", gui=True)
        try:
            code, _, body = gui.request({"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                         "params": {"name": "wechat_status", "arguments": {}}})
            assert code == 200 and json.loads(body)["result"]["isError"] is False
        finally:
            gui.close()
print("PASS: HTTP MCP negotiation, loopback isolation, bounded framing, parallel queries, port conflict, shutdown and restart")
