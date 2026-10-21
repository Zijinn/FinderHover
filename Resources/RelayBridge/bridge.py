#!/usr/bin/env python3
"""Local Messages API bridge. One process per provider, stdlib only."""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import re
import signal
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 64 * 1024 * 1024
MAX_REPLY = 64 * 1024 * 1024


def endpoint(base: str, leaf: str) -> str:
    base = base.rstrip('/')
    return base + ('/' + leaf if base.endswith('/v1') else '/v1/' + leaf)


def validate_config(config: dict) -> dict:
    result = dict(config)
    parsed = urllib.parse.urlsplit(result.get('upstream', ''))
    if parsed.scheme not in ('http', 'https') or not parsed.hostname:
        raise ValueError('接口地址必须为 http:// 或 https:// URL。')
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('接口地址不能包含用户名、密码、查询参数或片段。')
    if parsed.path.rstrip('/').endswith('/messages'):
        raise ValueError('填写接口基础地址，不要追加 /messages。')
    result['upstream'] = result['upstream'].rstrip('/')
    result['port'] = int(result.get('port', 8181))
    if not 1024 <= result['port'] <= 65535:
        raise ValueError('端口必须在 1024 至 65535 之间。')
    if result.get('mode', 'generic') not in ('generic', 'justwoker'):
        raise ValueError('未知兼容模式。')
    if result.get('auth', 'preserve') not in ('preserve', 'bearer', 'x-api-key'):
        raise ValueError('未知认证方式。')
    result['timeout'] = min(600, max(5, int(result.get('timeout', 300))))
    result['model'] = str(result.get('model', '')).strip()
    if result.get('overrideModel') and not result['model']:
        raise ValueError('覆盖模型时必须填写上游模型名称。')
    return result


def events_for_message(message: dict):
    """Emit the Messages stream contract, including signed thinking and tools."""
    usage = dict(message.get('usage') or {})
    output_tokens = usage.get('output_tokens', 0)
    usage['output_tokens'] = 0
    yield {'type': 'message_start', 'message': {
        'id': message.get('id') or 'msg_' + uuid.uuid4().hex,
        'type': 'message', 'role': 'assistant', 'model': message.get('model', ''),
        'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': usage,
    }}
    for index, original in enumerate(message.get('content') or []):
        block = copy.deepcopy(original)
        kind = block.get('type')
        deltas = []
        if kind == 'text':
            text = block.pop('text', '')
            citations = block.pop('citations', [])
            block['text'] = ''
            if text:
                deltas.append({'type': 'text_delta', 'text': text})
            if citations:
                block['citations'] = []
                deltas.extend({'type': 'citations_delta', 'citation': c} for c in citations)
        elif kind in ('tool_use', 'server_tool_use'):
            arguments = block.pop('input', {})
            block['input'] = {}
            deltas.append({'type': 'input_json_delta',
                           'partial_json': json.dumps(arguments, ensure_ascii=False)})
        elif kind == 'thinking':
            thinking = block.pop('thinking', '')
            signature = block.pop('signature', '')
            block['thinking'] = ''
            if thinking:
                deltas.append({'type': 'thinking_delta', 'thinking': thinking})
            if signature:
                deltas.append({'type': 'signature_delta', 'signature': signature})
        # Other typed result blocks, including redacted_thinking, are sent whole.
        yield {'type': 'content_block_start', 'index': index, 'content_block': block}
        for delta in deltas:
            yield {'type': 'content_block_delta', 'index': index, 'delta': delta}
        yield {'type': 'content_block_stop', 'index': index}
    yield {'type': 'message_delta', 'delta': {
        'stop_reason': message.get('stop_reason') or 'end_turn',
        'stop_sequence': message.get('stop_sequence'),
    }, 'usage': {'output_tokens': output_tokens}}
    yield {'type': 'message_stop'}


def visible_content(message: dict) -> bool:
    return any(isinstance(b, dict) and (
        b.get('type') in ('tool_use', 'server_tool_use')
        or b.get('type') == 'text' and bool(b.get('text', '').strip())
        or b.get('type') not in ('thinking', 'redacted_thinking', 'text')
    ) for b in message.get('content') or [])


def load_compat():
    path = Path(__file__).with_name('justwoker_compat.py')
    spec = importlib.util.spec_from_file_location('relaybridge_justwoker', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Suppress the original request-content logger. Log status only in this app.
    module.log_message = lambda *_: None
    return module


class BridgeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, config, address=None):
        self.config = validate_config(config)
        self.compat = load_compat() if self.config.get('mode') == 'justwoker' else None
        self.stats_lock = threading.Lock()
        self.stats = {'requests': 0, 'completed': 0, 'failed': 0, 'active': 0,
                      'lastStatus': '', 'lastDuration': 0}
        super().__init__(address or ('127.0.0.1', self.config['port']), Handler)

    def note(self, **updates):
        with self.stats_lock:
            for k, v in updates.items():
                if k in ('requests', 'completed', 'failed', 'active'):
                    self.stats[k] += v
                else:
                    self.stats[k] = v


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def permitted_host(self):
        # Avoid DNS rebinding. This listener never binds beyond loopback.
        try:
            host = urllib.parse.urlsplit('http://' + self.headers.get('Host', '')).hostname
        except ValueError:
            return False
        return host in ('127.0.0.1', 'localhost', '::1')

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def fail(self, status, kind, message):
        self.reply(status, {'type': 'error', 'error': {'type': kind, 'message': message}})

    def do_GET(self):
        if not self.permitted_host():
            self.fail(403, 'permission_error', '仅接受本机地址请求。')
            return
        path = urllib.parse.urlsplit(self.path).path.rstrip('/')
        if path == '/health':
            with self.server.stats_lock:
                stats = dict(self.server.stats)
            self.reply(200, {'status': 'ok', 'profileID': self.server.config.get('id'),
                             'pid': os.getpid(), 'stats': stats})
        elif path == '/v1/models':
            model = self.server.config['model']
            models = [{'id': model, 'type': 'model', 'display_name': model,
                       'created_at': '2026-10-07T00:00:00Z'}] if model else []
            self.reply(200, {'data': models, 'has_more': False,
                             'first_id': model or None, 'last_id': model or None})
        else:
            self.fail(404, 'not_found_error', '此工具支持 /v1/messages 和 /v1/models。')

    def read_json(self):
        if self.headers.get('Transfer-Encoding'):
            raise ValueError('请使用 Content-Length 发送请求。')
        length = int(self.headers.get('Content-Length') or '0')
        if not 0 < length <= MAX_BODY:
            raise ValueError('请求体为空或超过 64MB。')
        body = json.loads(self.rfile.read(length))
        if not isinstance(body, dict):
            raise ValueError('请求体必须是 JSON 对象。')
        return body

    def auth_headers(self):
        config = self.server.config
        key = self.headers.get('x-api-key', '').strip()
        authorization = self.headers.get('Authorization', '').strip()
        if not key and authorization.lower().startswith('bearer '):
            key = authorization[7:].strip()
        if not key:
            key = config.get('apiKey', '')
        if not key:
            raise PermissionError('客户端未发送密钥，请在客户端填写或在工具中保存密钥。')
        headers = {'Content-Type': 'application/json', 'User-Agent': 'RelayBridge/1.0',
                   'anthropic-version': self.headers.get('anthropic-version', '2023-06-01')}
        # Preserve negotiated protocol features; never forward cookies or Host.
        for name in ('anthropic-beta', 'anthropic-dangerous-direct-browser-access'):
            if self.headers.get(name):
                headers[name] = self.headers[name]
        auth = config.get('auth', 'preserve')
        if auth == 'bearer' or auth == 'preserve' and authorization:
            headers['Authorization'] = 'Bearer ' + key
        else:
            headers['x-api-key'] = key
        return headers

    def upstream(self, body, headers, leaf='messages'):
        query = urllib.parse.urlsplit(self.path).query
        url = endpoint(self.server.config['upstream'], leaf)
        if query:
            url += '?' + query
        request = urllib.request.Request(url, method='POST', headers=headers,
                                         data=json.dumps(body, ensure_ascii=False).encode())
        # No automatic retry: a lost reply can already have been billed.
        with urllib.request.urlopen(request, timeout=self.server.config['timeout']) as response:
            data = response.read(MAX_REPLY + 1)
            if len(data) > MAX_REPLY:
                raise ValueError('上游响应超过 64MB。')
            result = json.loads(data)
            if leaf == 'messages/count_tokens':
                if not isinstance(result, dict) or not isinstance(result.get('input_tokens'), int):
                    raise ValueError('上游没有返回有效 token 数。')
                return result
            if not isinstance(result, dict) or not isinstance(result.get('content'), list):
                raise ValueError('上游没有返回 Anthropic Messages 的完整 JSON content。')
            return result

    def do_POST(self):
        if not self.permitted_host():
            self.fail(403, 'permission_error', '仅接受本机地址请求。')
            return
        if self.headers.get('Origin') not in (None, 'app://localhost'):
            self.fail(403, 'permission_error', '此端口供桌面客户端使用。')
            return
        path = urllib.parse.urlsplit(self.path).path.rstrip('/')
        if path not in ('/v1/messages', '/v1/messages/count_tokens'):
            self.fail(404, 'not_found_error', '仅支持 Anthropic Messages API。')
            return
        start = time.monotonic()
        self.server.note(requests=1, active=1)
        stream_started = False
        try:
            body = self.read_json()
            if not isinstance(body.get('messages'), list) or not body.get('model'):
                raise ValueError('请求必须包含 model 和 messages。')
            wants_stream = body.get('stream', False) is True
            headers = self.auth_headers()
            asked_model = body['model']
            if self.server.config.get('overrideModel'):
                body['model'] = self.server.config['model']
            if path == '/v1/messages/count_tokens':
                if self.server.compat:
                    result = {'input_tokens': self.server.compat.estimate_input_tokens(
                        json.dumps(body, ensure_ascii=False).encode())}
                else:
                    result = self.upstream(body, headers, leaf='messages/count_tokens')
                self.reply(200, result)
                self.server.note(completed=1, lastStatus='200')
                return
            body['stream'] = False
            compat = self.server.compat
            tools = copy.deepcopy(body.get('tools') or [])
            tools_in_play = bool(tools) or (compat and compat.has_tool_blocks(body['messages']))
            reverse = {}
            if compat and tools_in_play:
                body, reverse = compat.apply_tool_emulation(body)
            result = self.upstream(body, headers)
            if compat:
                if tools_in_play:
                    result = compat.remap_tool_calls(compat.extract_tool_calls(result), tools, reverse)
                    # Some relay tool calls incorrectly report end_turn.
                    if any(b.get('type') == 'tool_use' for b in result['content']):
                        result['stop_reason'] = 'tool_use'
                result = compat.sanitize_usage(result, len(json.dumps(body, ensure_ascii=False).encode()))
            if not visible_content(result):
                raise ValueError('上游非流式回复也没有正文或工具调用；代理无法补出不存在的内容。')
            if self.server.config.get('overrideModel'):
                result['model'] = asked_model
            if wants_stream:
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('X-Accel-Buffering', 'no')
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                stream_started = True
                for event in events_for_message(result):
                    data = ('event: ' + event['type'] + '\ndata: ' +
                            json.dumps(event, ensure_ascii=False) + '\n\n').encode()
                    self.wfile.write(b'%x\r\n%s\r\n' % (len(data), data))
                    self.wfile.flush()
                self.wfile.write(b'0\r\n\r\n')
                self.wfile.flush()
            else:
                self.reply(200, result)
            self.server.note(completed=1, lastStatus='200')
        except urllib.error.HTTPError as error:
            self.server.note(failed=1, lastStatus=str(error.code))
            # Include neither credentials nor raw upstream error bodies in logs.
            self.fail(error.code, 'upstream_error', f'上游返回 HTTP {error.code}。请检查密钥、模型或接口状态。')
        except PermissionError as error:
            self.server.note(failed=1, lastStatus='401')
            self.fail(401, 'authentication_error', str(error))
        except (ValueError, json.JSONDecodeError) as error:
            self.server.note(failed=1, lastStatus='502')
            self.fail(502, 'bridge_error', str(error)[:250])
        except (BrokenPipeError, ConnectionResetError):
            self.server.note(failed=1, lastStatus='客户端断开')
        except Exception as error:
            self.server.note(failed=1, lastStatus='502')
            if not stream_started:
                self.fail(502, 'connection_error', f'连接上游失败（{type(error).__name__}）。')
        finally:
            self.server.note(active=-1, lastDuration=round(time.monotonic() - start, 2))


def import_ccswitch():
    """Explicit GUI action: return provider drafts; do not modify CC Switch."""
    database = Path.home() / '.cc-switch/cc-switch.db'
    if not database.exists():
        raise ValueError('未找到 CC Switch 数据库。')
    connection = sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
    try:
        rows = connection.execute(
            "SELECT id, name, settings_config, meta FROM providers "
            "WHERE app_type='claude-desktop' ORDER BY sort_index, name").fetchall()
    finally:
        connection.close()
    providers = []
    for identifier, name, raw, meta_raw in rows:
        settings, meta = json.loads(raw), json.loads(meta_raw)
        env = settings.get('env', {})
        base = env.get('ANTHROPIC_BASE_URL', '')
        if not base or meta.get('apiFormat', 'anthropic') != 'anthropic':
            continue
        if urllib.parse.urlsplit(base).hostname in ('localhost', '127.0.0.1', '::1'):
            continue
        routes = meta.get('claudeDesktopModelRoutes') or {}
        model = next((v.get('model') or k for k, v in routes.items() if isinstance(v, dict)), '')
        providers.append({'sourceID': identifier, 'name': name, 'upstream': base,
                          'model': model or env.get('ANTHROPIC_MODEL', '').replace('[1m]', ''),
                          'apiKey': env.get('ANTHROPIC_AUTH_TOKEN') or env.get('ANTHROPIC_API_KEY', '')})
    return providers


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--import-ccswitch', action='store_true')
    args = parser.parse_args()
    if args.import_ccswitch:
        try:
            print(json.dumps(import_ccswitch(), ensure_ascii=False))
        except Exception:
            print('[]')
            return 1
        return 0
    # The application delivers keys via a private pipe, never command arguments.
    config = json.loads(sys.stdin.readline())
    server = BridgeServer(config)
    sys.stdin.close()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    print(json.dumps({'ready': True, 'port': server.server_port}), flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({'ready': False, 'error': type(error).__name__}), flush=True)
        raise SystemExit(1)
