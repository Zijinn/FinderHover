"""Network contract tests against local fixtures, no vendor credentials."""
import concurrent.futures
import copy
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import bridge


class FakeUpstream(BaseHTTPRequestHandler):
    seen = []
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with self.lock:
            self.seen.append({'body': body, 'path': self.path, 'headers': dict(self.headers)})
        if self.path.startswith('/v1/messages/count_tokens'):
            data = json.dumps({'input_tokens': 4321}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        model = body['model']
        content = [{'type': 'text', 'text': model + ' OK'}]
        if model == 'signed':
            content = [{'type': 'thinking', 'thinking': 'fixture thought', 'signature': 'SIGNED_FIXTURE'},
                       {'type': 'tool_use', 'id': 'toolu_fixture', 'name': 'Read',
                        'input': {'file_path': '/fixture.txt'}}]
        elif model == 'invisible':
            content = [{'type': 'thinking', 'thinking': 'fixture', 'signature': 'SIGNATURE'}]
        elif model == 'denied':
            self.send_response(401)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        result = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant', 'model': model,
                  'content': content, 'stop_reason': 'tool_use' if model == 'signed' else 'end_turn',
                  'usage': {'input_tokens': 7, 'output_tokens': 11, 'cache_read_input_tokens': 13}}
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class BridgeContract(unittest.TestCase):
    def setUp(self):
        self.servers = []
        self.upstream = ThreadingHTTPServer(('127.0.0.1', 0), FakeUpstream)
        self.run_server(self.upstream)
        self.base = 'http://127.0.0.1:' + str(self.upstream.server_port)
        FakeUpstream.seen = []

    def run_server(self, server):
        self.servers.append(server)
        threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True).start()
        return server

    def make_bridge(self, **options):
        cfg = {'id': 'test-profile', 'upstream': self.base, 'port': 8181,
               'model': '', 'auth': 'preserve', 'mode': 'generic', 'timeout': 5}
        cfg.update(options)
        return self.run_server(bridge.BridgeServer(cfg, ('127.0.0.1', 0)))

    def call(self, server, model='test', stream=True, headers=None, **options):
        body = {'model': model, 'stream': stream, 'max_tokens': 64,
                'messages': [{'role': 'user', 'content': 'fixture'}]}
        body.update(options)
        hdrs = {'Content-Type': 'application/json', 'Authorization': 'Bearer test-key',
                'anthropic-beta': 'fixture-beta'}
        if headers:
            hdrs.update(headers)
        req = urllib.request.Request('http://127.0.0.1:' + str(server.server_port) +
                                     '/v1/messages?beta=true', data=json.dumps(body).encode(), headers=hdrs)
        with urllib.request.urlopen(req, timeout=5) as response:
            raw = response.read().decode()
            return [json.loads(line[6:]) for line in raw.splitlines() if line.startswith('data: ')] if stream else json.loads(raw)

    def tearDown(self):
        for server in reversed(self.servers):
            server.shutdown()
            server.server_close()

    def test_stream_is_reconstructed_and_upstream_forced_nonstream(self):
        server = self.make_bridge()
        events = self.call(server, model='native-model')
        self.assertEqual([e['type'] for e in events], ['message_start', 'content_block_start',
                         'content_block_delta', 'content_block_stop', 'message_delta', 'message_stop'])
        self.assertEqual(events[2]['delta']['text'], 'native-model OK')
        captured = FakeUpstream.seen[-1]
        self.assertFalse(captured['body']['stream'])
        self.assertEqual(captured['path'], '/v1/messages?beta=true')
        self.assertEqual(captured['headers']['Authorization'], 'Bearer test-key')
        self.assertEqual(captured['headers']['Anthropic-Beta'], 'fixture-beta')
        self.assertEqual(events[0]['message']['usage']['cache_read_input_tokens'], 13)

    def test_thinking_signature_and_tool_arguments_survive(self):
        server = self.make_bridge()
        events = self.call(server, model='signed')
        deltas = [e['delta'] for e in events if e['type'] == 'content_block_delta']
        self.assertIn({'type': 'signature_delta', 'signature': 'SIGNED_FIXTURE'}, deltas)
        args = next(d['partial_json'] for d in deltas if d['type'] == 'input_json_delta')
        self.assertEqual(json.loads(args), {'file_path': '/fixture.txt'})
        self.assertEqual(events[-2]['delta']['stop_reason'], 'tool_use')

    def test_concurrent_providers_do_not_mix_model_or_credentials(self):
        a = self.make_bridge(id='a', model='A', overrideModel=True, auth='x-api-key')
        b = self.make_bridge(id='b', model='B', overrideModel=True, auth='bearer')
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            f1 = pool.submit(self.call, a, headers={'Authorization': 'Bearer A-key'})
            f2 = pool.submit(self.call, b, headers={'Authorization': 'Bearer B-key'})
            events_a, events_b = f1.result(), f2.result()
        self.assertEqual(events_a[2]['delta']['text'], 'A OK')
        self.assertEqual(events_b[2]['delta']['text'], 'B OK')
        rows = {r['body']['model']: r for r in FakeUpstream.seen}
        self.assertEqual(rows['A']['headers']['X-Api-Key'], 'A-key')
        self.assertEqual(rows['B']['headers']['Authorization'], 'Bearer B-key')
        self.assertEqual(events_a[0]['message']['model'], 'test')

    def test_generic_tools_are_not_renamed_or_prompt_injected(self):
        server = self.make_bridge()
        tools = [{'name': 'CustomTool', 'input_schema': {'type': 'object'}}]
        self.call(server, tools=tools, system='original system')
        body = FakeUpstream.seen[-1]['body']
        self.assertEqual(body['tools'], tools)
        self.assertEqual(body['system'], 'original system')

    def test_empty_visible_output_is_explicit_error(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.call(self.make_bridge(), model='invisible')
        self.assertEqual(error.exception.code, 502)
        self.assertIn('没有正文', error.exception.read().decode())

    def test_upstream_auth_failure_is_not_retried(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.call(self.make_bridge(), model='denied')
        self.assertEqual(error.exception.code, 401)
        self.assertEqual(len(FakeUpstream.seen), 1)

    def test_nonstream_and_v1_base_url(self):
        server = self.make_bridge(upstream=self.base + '/v1')
        message = self.call(server, stream=False)
        self.assertEqual(message['content'][0]['text'], 'test OK')
        self.assertEqual(FakeUpstream.seen[-1]['path'], '/v1/messages?beta=true')

    def test_health_and_models_do_not_expose_key(self):
        server = self.make_bridge(apiKey='private-key', model='display-model')
        for path in ['/health', '/v1/models']:
            with urllib.request.urlopen('http://127.0.0.1:' + str(server.server_port) + path) as response:
                raw = response.read().decode()
                self.assertNotIn('private-key', raw)
                self.assertIsInstance(json.loads(raw), dict)

    def test_browser_origin_and_rebinding_host_are_rejected(self):
        server = self.make_bridge()
        for headers in [{'Origin': 'https://example.com'}, {'Host': 'evil.example'}]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.call(server, headers=headers)
            self.assertEqual(error.exception.code, 403)
        self.assertEqual(FakeUpstream.seen, [])

    def test_generic_count_tokens_uses_authoritative_upstream(self):
        server = self.make_bridge()
        request = urllib.request.Request('http://127.0.0.1:' + str(server.server_port) +
            '/v1/messages/count_tokens', headers={'Authorization': 'Bearer test-key'},
            data=json.dumps({'model': 'test', 'messages': []}).encode())
        with urllib.request.urlopen(request) as response:
            self.assertEqual(json.loads(response.read()), {'input_tokens': 4321})
        self.assertEqual(FakeUpstream.seen[-1]['path'], '/v1/messages/count_tokens')


if __name__ == '__main__':
    unittest.main(verbosity=2)
