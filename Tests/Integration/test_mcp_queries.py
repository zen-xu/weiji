#!/usr/bin/env python3
"""Synthetic AI discovery workflow over both stdio and real loopback HTTP, without image decoding."""
import json
import pathlib
import subprocess
import sys
import tempfile
import uuid

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
            assert len(tools) == 16
            assert tools['wechat_search_messages']['inputSchema']['properties']['detail']['default'] == 'full'
            assert tool('wechat_search_messages')['structuredContent']['error']['code'] == 'archive_not_available'
            assert not archive.exists()
            # Reminder configuration is the only writable surface; testing is side-effect free.
            initial = tool('wechat_list_reminder_rules')['structuredContent']
            assert initial['revision'] == 'initial' and initial['rules'] == [] and not archive.exists()
            rule = {'id': str(uuid.uuid4()), 'name': '项目紧急消息', 'match': 'all',
                    'minimum_interval_seconds': 300, 'quiet_hours': {'start_minute': 1320, 'end_minute': 480}, 'conditions': [
                {'field': 'conversation', 'operator': 'equals', 'value': '项目群'},
                {'field': 'sender', 'operator': 'regex', 'value': '^(张三|李四)$'},
                {'field': 'body', 'operator': 'contains', 'value': '紧急'},
                {'field': 'body', 'operator': 'notContains', 'value': '演练'},
            ]}
            sample = {'conversation': '项目群', 'sender': '张三', 'body': '紧急：确认发布', 'conversation_kind': 'group'}
            tested = tool('wechat_test_reminder_rule', {'rule': rule, 'sample': sample})['structuredContent']
            assert tested['matched'] and not tested['saved'] and not archive.exists()
            for change in ({'sender': '王五'}, {'body': '紧急演练'}, {'conversation': '其他频道'}):
                assert not tool('wechat_test_reminder_rule', {'rule': rule, 'sample': dict(sample, **change)})['structuredContent']['matched']
            saved = tool('wechat_save_reminder_rule', {'rule': rule, 'expected_revision': initial['revision']})['structuredContent']
            assert len(saved['rules']) == 1 and not (archive / 'archive.sqlite').exists()
            assert saved['rules'][0]['minimum_interval_seconds'] == 300
            assert saved['rules'][0]['quiet_hours'] == rule['quiet_hours']
            assert (archive / 'reminder-rules.json').stat().st_mode & 0o777 == 0o600
            assert not (archive / 'preferences.json').exists()
            stale = tool('wechat_delete_reminder_rule', {'id': rule['id'], 'expected_revision': initial['revision']})
            assert stale['isError'] and stale['structuredContent']['error']['code'] == 'reminder_revision_conflict'
            # Independent stdio process sees writes from either transport without restarting the source server.
            other_requests = [
                {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'wechat_list_reminder_rules'}},
            ]
            other = subprocess.run([str(binary), 'mcp', '--data-dir', str(archive)], input=''.join(json.dumps(r) + '\n' for r in other_requests),
                                   check=True, capture_output=True, text=True)
            other_rules = json.loads(other.stdout.splitlines()[1])['result']['structuredContent']
            assert other_rules == saved
            invalid_rule = dict(rule, conditions=[{'field': 'body', 'operator': 'regex', 'value': '['}])
            invalid = tool('wechat_save_reminder_rule', {'rule': invalid_rule, 'expected_revision': saved['revision']})
            assert invalid['isError'] and invalid['structuredContent']['error']['code'] == 'invalid_arguments'
            assert tool('wechat_list_reminder_rules')['structuredContent'] == saved
            deleted = tool('wechat_delete_reminder_rule', {'id': rule['id'], 'expected_revision': saved['revision']})['structuredContent']
            assert deleted['rules'] == []
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
