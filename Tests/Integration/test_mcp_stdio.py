#!/usr/bin/env python3
"""Black-box MCP and CLI verification. Uses synthetic fixtures only; no network."""
import json
import base64
import hashlib
import datetime
import os
import pathlib
import sqlite3
import subprocess
import sys
import tempfile

binary = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="wechat-mcp-fixture-") as directory:
    root = pathlib.Path(directory)
    untouched = root / "cli-metadata-must-not-create-an-archive"
    version = subprocess.run([str(binary), "--version", "--data-dir", str(untouched)],
                             check=True, capture_output=True, text=True).stdout.strip()
    assert version and "\n" not in version
    help_text = subprocess.run([str(binary), "--help", "--data-dir", str(untouched)],
                               check=True, capture_output=True, text=True).stdout
    assert f"微信消息监听 {version}" in help_text
    retired = subprocess.run([str(binary), "--self-test", "--data-dir", str(untouched)],
                             capture_output=True, text=True)
    assert retired.returncode != 0 and "Scripts/test.sh" in json.loads(retired.stdout)["error"]
    assert not untouched.exists(), "Metadata and retired self-test commands must not create an archive"
    data_dir = root / "archive"
    process = subprocess.Popen([str(binary), "mcp", "--data-dir", str(data_dir)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding="utf-8")
    def send(value):
        process.stdin.write(json.dumps(value, ensure_ascii=False) + "\n")
        process.stdin.flush()
    def call(number, method, params=None):
        send({"jsonrpc": "2.0", "id": number, "method": method, "params": params or {}})
        line = process.stdout.readline()
        assert line, "Server exited before responding"
        response = json.loads(line)
        assert response["id"] == number, response
        return response
    assert call(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                  "clientInfo": {"name": "fixture-mcp-client", "version": "1"}})["result"]["protocolVersion"] == "2025-06-18"
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    assert call(2, "ping")["result"] == {}
    tools = call(3, "tools/list")["result"]["tools"]
    assert len(tools) == 6
    assert all(tool["annotations"]["readOnlyHint"] for tool in tools)
    status = call(4, "tools/call", {"name": "wechat_status", "arguments": {}})["result"]
    assert status["structuredContent"]["archive_available"] is False
    assert not data_dir.exists(), "Read-only MCP status must not create the archive"
    fixture = root / "legacy.jsonl"
    records = [
        {"record_id": n, "app": "com.tencent.xinWeChat", "title": "fixture-private-contact",
         "subtitle": "", "body": f"报价单第{n}条\n第二行", "captured_at": f"2026-10-15T01:0{n}:00Z",
         "delivered_at": f"2026-10-15T01:0{n}:00Z"}
        for n in range(1, 4)
    ]
    fixture.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in records))
    imported = subprocess.run([str(binary), "import", "--input", str(fixture), "--data-dir", str(data_dir)],
                              check=True, capture_output=True, text=True)
    assert json.loads(imported.stdout)["inserted"] == 3
    result = call(5, "tools/call", {"name": "wechat_search_messages", "arguments": {"query": "报价单", "limit": 2}})["result"]
    assert result["isError"] is False
    value = result["structuredContent"]
    assert value["total"] == 3 and len(value["messages"]) == 2 and value["has_more"] is True
    assert json.loads(result["content"][0]["text"]) == value
    message = value["messages"][0]
    assert message["is_complete_chat"] is False and message["includes_sent_messages"] is False
    assert "attachments" not in message and message["presentation"]["body"] == message["body"]
    with sqlite3.connect(data_dir / "archive.sqlite") as database:
        assert not database.execute("SELECT name FROM sqlite_master WHERE name='attachments'").fetchall()
        database.execute("CREATE TABLE attachments(id TEXT,message_id TEXT,local_path TEXT)")
        database.execute("INSERT INTO attachments VALUES(?,?,?)", ("legacy", message["id"], "/synthetic/old-attachment.png"))
    anchor = call(6, "tools/call", {"name": "wechat_get_context", "arguments": {"message_id": message["id"], "radius": 1}})["result"]
    assert anchor["isError"] is False
    assert anchor["structuredContent"]["anchor_message_id"] == message["id"]
    assert all("attachments" not in item for item in anchor["structuredContent"]["messages"])
    assert "/synthetic/old-attachment.png" not in json.dumps(anchor)
    bad = call(7, "tools/call", {"name": "wechat_search_messages", "arguments": {"limit": 100000}})["result"]
    assert bad["isError"] is True
    resource = call(8, "resources/read", {"uri": "wechat://coverage"})["result"]
    assert resource["contents"][0]["mimeType"] == "text/plain"
    assert "error" in call(9, "tools/call", {"name": "run_shell", "arguments": {"command": "anything"}})
    send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 7}})
    assert call(10, "ping")["result"] == {}, "Notifications must not produce stray responses"
    account = root / "synthetic-account"
    file_root = account / "msg/file/2026-10"
    file_root.mkdir(parents=True)
    (file_root / "合成报价单.pdf").write_bytes(b"%PDF-1.4\nSYNTHETIC_PRIVATE_CONTENT_NOT_FOR_MCP")
    (file_root / "image.png").write_bytes(b"synthetic excluded image")
    scan = subprocess.run([str(binary), "scan-files", "--directory", str(account), "--data-dir", str(data_dir)],
                          check=True, capture_output=True, text=True)
    assert json.loads(scan.stdout)["files"] == 1
    discovered = call(11, "tools/call", {"name": "wechat_search_files", "arguments": {"query": "报价"}})["result"]
    assert discovered["structuredContent"]["total"] == 1
    assert discovered["structuredContent"]["files"][0]["local_path"] == str(file_root / "合成报价单.pdf")
    assert "SYNTHETIC_PRIVATE_CONTENT_NOT_FOR_MCP" not in json.dumps(discovered)
    forbidden_scan = call(12, "tools/call", {"name": "wechat_search_files", "arguments": {"directory": "/"}})["result"]
    assert forbidden_scan["isError"] is True
    image = dict(message)
    image.update(id=hashlib.sha256(b"fixture-image-message").hexdigest(),
                 source_key=hashlib.sha256(b"fixture-image-source").hexdigest(),
                 content_hash=hashlib.sha256(b"fixture-image-body").hexdigest(),
                 conversation_id=hashlib.sha256(b"fixture-image-conversation").hexdigest(),
                 conversation_name="fixture-image-group", conversation_kind="group",
                 conversation_id_source="notification_chatname", body="[图片]",
                 media_directory_id=hashlib.md5(b"fixture-image@chatroom").hexdigest())
    image_json = root / "image.jsonl"
    image_json.write_text(json.dumps(image, ensure_ascii=False) + "\n")
    subprocess.run([str(binary), "import", "--input", str(image_json), "--data-dir", str(data_dir)], check=True, capture_output=True)
    image_root = account / "msg/attach" / image["media_directory_id"] / "2026-10/Img"
    image_root.mkdir(parents=True)
    image_file = image_root / "fixtureasset.dat"
    image_file.write_bytes(bytes([7, 8, 86, 50, 8, 7]) + b"SYNTHETIC_ENCRYPTED_BYTES_NOT_FOR_MCP")
    image_at = datetime.datetime.fromisoformat(image["delivered_at"].replace("Z", "+00:00")).timestamp() + 0.2
    os.utime(image_file, (image_at, image_at))
    image_scan = subprocess.run([str(binary), "scan-files", "--directory", str(account), "--data-dir", str(data_dir)], check=True, capture_output=True, text=True)
    assert json.loads(image_scan.stdout)["image_associations"]["files"] == 1
    linked_image = call(13, "tools/call", {"name": "wechat_search_messages", "arguments": {"query": "[图片]"}})["result"]
    association = linked_image["structuredContent"]["messages"][0]["image_associations"][0]
    assert association["local_path"] == str(image_file)
    assert abs(association["seconds_from_notification"] - 0.2) < 0.002
    assert association["assessment_by"] == "ai_client" and "confidence" not in association
    assert "SYNTHETIC_ENCRYPTED_BYTES_NOT_FOR_MCP" not in json.dumps(linked_image)
    # A complete synthetic JPEG verifies the deployed CLI -> cache -> MCP image-content path.
    image_file.write_bytes(base64.b64decode("/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMQD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABLAAEBAAAAAAAAAAAAAAAAAAAABgEBAAAAAAAAAAAAAAAAAAAABhABAAAAAAAAAAAAAAAAAAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIABAAEAMBIgACEQADEQD/2gAMAwEAAhEDEQA/AIsAUCX/2Q=="))
    os.utime(image_file, (image_at, image_at))
    subprocess.run([str(binary), "scan-files", "--directory", str(account), "--data-dir", str(data_dir)], check=True, capture_output=True)
    image_result = call(14, "tools/call", {"name": "wechat_search_messages", "arguments": {"query": "[图片]"}})["result"]["structuredContent"]["messages"][0]
    linked = image_result["image_associations"][0]
    assert linked["preview"]["state"] == "ready"
    rendered = call(15, "tools/call", {"name": "wechat_get_image", "arguments": {"message_id": image_result["id"], "file_id": linked["id"]}})["result"]
    assert rendered["isError"] is False and rendered["content"][1]["type"] == "image"
    assert base64.b64decode(rendered["content"][1]["data"]).startswith(b"\xff\xd8\xff")
    forbidden = call(16, "tools/call", {"name": "wechat_get_image", "arguments": {"message_id": image_result["id"], "file_id": linked["id"], "path": "/etc/passwd"}})["result"]
    assert forbidden["isError"] is True
    larger_variant = image_root / "fixtureasset_h.dat"
    larger_variant.write_bytes(image_file.read_bytes())
    os.utime(larger_variant, (image_at + 600, image_at + 600))
    subprocess.run([str(binary), "scan-files", "--directory", str(account), "--data-dir", str(data_dir)], check=True, capture_output=True)
    expanded = call(17, "tools/call", {"name": "wechat_search_messages", "arguments": {"query": "[图片]"}})["result"]["structuredContent"]["messages"][0]["image_associations"]
    assert len(expanded) == 2 and sum(bool(x["preferred_for_preview"]) for x in expanded) == 1
    late = next(x for x in expanded if x["local_path"] == str(larger_variant))
    assert late["within_time_window"] is False and late["association_basis"] == "same_asset_family_as_timestamp_candidate"
    assert late["anchor_file_ids"] == [linked["id"]] and late["preview"]["state"] == "ready"
    fallback = dict(image)
    fallback.update(id=hashlib.sha256(b"fixture-fallback-message").hexdigest(),
                    source_key=hashlib.sha256(b"fixture-fallback-source").hexdigest(),
                    content_hash=hashlib.sha256(b"fixture-fallback-body").hexdigest(),
                    conversation_id=hashlib.sha256(b"fixture-fallback-conversation").hexdigest(),
                    media_directory_id=hashlib.md5(b"fixture-fallback-peer").hexdigest(),
                    body="合成目录线索文字")
    fallback_json = root / "fallback.jsonl"
    fallback_json.write_text(json.dumps(fallback, ensure_ascii=False) + "\n")
    subprocess.run([str(binary), "import", "--input", str(fallback_json), "--data-dir", str(data_dir)], check=True, capture_output=True)
    fallback_folder = account / "msg/attach" / fallback["media_directory_id"] / "2026-10/Img"
    fallback_folder.mkdir(parents=True)
    fallback_file = fallback_folder / "observed_t.dat"
    fallback_file.write_bytes(image_file.read_bytes())
    os.utime(fallback_file, (image_at, image_at))
    subprocess.run([str(binary), "scan-files", "--directory", str(account), "--data-dir", str(data_dir)], check=True, capture_output=True)
    observed = call(18, "tools/call", {"name": "wechat_search_messages", "arguments": {"query": "合成目录线索文字"}})["result"]["structuredContent"]["messages"][0]
    candidate = observed["image_associations"][0]
    assert observed["body"] == "合成目录线索文字" and candidate["image_notification_captured"] is False
    assert candidate["sender_verified"] is False and candidate["notification_anchor_kind"] == "nearby_conversation_notification"
    observed_image = call(19, "tools/call", {"name": "wechat_get_image", "arguments": {"message_id": observed["id"], "file_id": candidate["id"]}})["result"]
    assert observed_image["isError"] is False and observed_image["content"][1]["type"] == "image"
    process.stdin.close()
    assert process.wait(timeout=5) == 0
    assert process.stdout.read() == "", "stdout must contain MCP JSON-RPC only"
    assert process.stderr.read() == "", "No message bodies or diagnostics should leak to stderr"
    read_status = subprocess.run([str(binary), "status", "--data-dir", str(data_dir)], check=True, capture_output=True, text=True)
    assert json.loads(read_status.stdout)["archive"]["messages"] == 5
print("PASS: real stdio MCP handshake, version negotiation, notifications, six tools, presentation, decoded image cache and actual image content, later asset-family variants, directory observations without image notifications, filename discovery via CLI, file metadata search without contents, no arbitrary scan requests, legacy attachment metadata ignored, pagination, context, invalid arguments, read-only startup, CLI import, clean EOF")
