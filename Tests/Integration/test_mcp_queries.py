#!/usr/bin/env python3
"""Synthetic AI discovery workflow over both stdio and real loopback HTTP, without image decoding."""
import json
import pathlib
import subprocess
import sys
import tempfile

from mcp_http_client import HTTPClient

binary = pathlib.Path(sys.argv[1]).resolve()
for http_mode in (False, True):
    with tempfile.TemporaryDirectory(prefix='weiji-query-workflow-') as temporary:
        root = pathlib.Path(temporary)
        archive = root / 'archive'
        client = HTTPClient(binary, archive) if http_mode else None
        process = client.process if client else subprocess.Popen(
            [str(binary), 'mcp', '--data-dir', str(archive)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        number = 0

        def rpc(method, params=None):
            global number
            number += 1
            value = {'jsonrpc': '2.0', 'id': number, 'method': method, 'params': params or {}}
            if client:
                code, _, body = client.request(value)
                assert code == 200
                response = json.loads(body)
            else:
                process.stdin.write(json.dumps(value, ensure_ascii=False) + '\n')
                process.stdin.flush()
                response = json.loads(process.stdout.readline())
            assert response['id'] == number and 'error' not in response
            return response['result']

        def tool(name, arguments=None):
            result = rpc('tools/call', {'name': name, 'arguments': arguments or {}})
            assert json.loads(result['content'][0]['text']) == result['structuredContent']
            return result

        try:
            hello = rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                       'clientInfo': {'name': 'synthetic-query-workflow', 'version': '1'}})
            assert 'detail=compact' in hello['instructions']
            tools = {entry['name']: entry for entry in rpc('tools/list')['tools']}
            assert len(tools) == 6
            assert tools['wechat_search_messages']['inputSchema']['properties']['detail']['default'] == 'full'
            assert tool('wechat_search_messages')['structuredContent']['error']['code'] == 'archive_not_available'
            assert not archive.exists()
            fixture = root / 'messages.jsonl'
            fixture.write_text(''.join(json.dumps({
                'record_id': i, 'app': 'com.tencent.xinWeChat', 'title': '合成群', 'subtitle': '',
                'body': '测试人: ' + '通知正文' * 100, 'captured_at': f'2026-10-15T01:0{i}:00Z',
                'delivered_at': f'2026-10-15T01:0{i}:00Z',
            }, ensure_ascii=False) + '\n' for i in range(3)))
            subprocess.run([str(binary), 'import', '--input', str(fixture), '--data-dir', str(archive)], check=True, capture_output=True)
            status = tool('wechat_status')['structuredContent']
            assert status['archive']['messages'] == 3 and status['timezone'] and status['current_time']
            conversations = tool('wechat_list_conversations', {'limit': 1, 'include_total': False})['structuredContent']
            assert conversations['total'] is None and conversations['next_offset'] is None
            conversation = conversations['conversations'][0]['id']
            compact = tool('wechat_search_messages', {'conversation_id': conversation, 'detail': 'compact',
                            'limit': 2, 'body_limit': 200, 'include_total': False})['structuredContent']
            assert compact['total'] is None and compact['has_more'] and compact['next_offset'] == 2
            assert compact['attachments_included'] is False and len(compact['messages']) == 2
            message = compact['messages'][0]
            assert message['body_truncated'] and len(message['body']) == 200
            assert message['sender_source'] == 'body_prefix_inferred'
            assert 'file_candidates' not in message and 'image_associations' not in message
            last = tool('wechat_search_messages', {'detail': 'compact', 'limit': 2, 'offset': compact['next_offset'],
                                                  'include_total': False})['structuredContent']
            assert last['returned'] == 1 and not last['has_more'] and last['next_offset'] is None
            full = tool('wechat_get_context', {'message_id': message['id'], 'radius': 0})['structuredContent']
            assert full['returned'] == 1 and full['messages'][0]['body'].startswith(message['body'])
            assert len(full['messages'][0]['body']) > len(message['body'])
            assert 'file_candidates' in full['messages'][0] and full['attachments_included']
            invalid = tool('wechat_search_messages', {'include_total': 1})
            assert invalid['isError'] and invalid['structuredContent']['error']['code'] == 'invalid_arguments'
            assert invalid['structuredContent']['error']['next_action']
            source = root / 'account/msg/file'
            source.mkdir(parents=True)
            for i in range(201):
                (source / f'file-{i:03}.pdf').write_bytes(b'SYNTHETIC_DOCUMENT_CONTENT_NOT_RETURNED')
            subprocess.run([str(binary), 'scan-files', '--directory', str(source), '--data-dir', str(archive)], check=True, capture_output=True)
            files = tool('wechat_search_files', {'limit': 200, 'include_total': False})['structuredContent']
            assert files['returned'] == 200 and files['has_more'] and files['next_offset'] == 200
            assert 'SYNTHETIC_DOCUMENT_CONTENT_NOT_RETURNED' not in json.dumps(files)
            final_files = tool('wechat_search_files', {'limit': 200, 'offset': 200})['structuredContent']
            assert final_files['total'] == 201 and final_files['returned'] == 1 and not final_files['has_more']
        finally:
            if client:
                client.close()
            else:
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                assert process.returncode == 0 and not process.stdout.read() and not process.stderr.read()
        print('PASS:', 'HTTP' if http_mode else 'stdio', 'compact discovery, detail recovery, pagination, errors and fresh scans')
