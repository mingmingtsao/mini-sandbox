"""Synthetic canaries only; no captured request bodies are fixtures."""
import json
import unittest
from test_capture import capture


class MetricsTests(unittest.TestCase):
    def test_structural_metrics_and_concrete_limits_without_values(self):
        self.assertTrue(hasattr(capture, 'structural_metrics'), 'opt-in structural metrics missing')
        canary = 'PRIVATE_CANARY_DO_NOT_RETAIN'
        value = {'stream': True, 'max_tokens': 32000,
                 'thinking': {'type': 'enabled', 'budget_tokens': 12000},
                 'output_config': {'effort': 'high'},
                 'system': [{'type': 'text', 'text': canary, 'cache_control': {'type': 'ephemeral'}}],
                 'messages': [{'role': 'user', 'content': canary}],
                 'tools': [{'name': canary, 'description': canary * 200,
                            'input_schema': {'type': 'object', 'properties': {canary: {'type': 'string'}}}}],
                 canary: canary}
        result = capture.structural_metrics(json.dumps(value).encode())
        self.assertEqual(result['stream'], True)
        self.assertEqual(result['max_tokens'], 32000)
        self.assertEqual(result['thinking'], 'enabled')
        self.assertEqual(result['thinking_budget'], 12000)
        self.assertEqual(result['effort'], 'high')
        self.assertEqual(result['system']['text_bytes'], len(canary))
        self.assertEqual(result['tools']['description_max'], len(canary) * 200)
        self.assertEqual(result['tools']['schema_depth_max'], 3)
        self.assertEqual(result['tools']['schema_nodes_max'], 5)
        self.assertEqual(result['tools']['schema_bytes_max'], len(json.dumps(value['tools'][0]['input_schema'], separators=(',', ':'), ensure_ascii=False).encode()))
        self.assertIn('max_tokens', result['mismatches'])
        self.assertIn('tool_description_bytes', result['mismatches'])
        self.assertIn('thinking', result['mismatches'])
        self.assertNotIn(canary, json.dumps(result))
        self.assertNotIn('metrics', capture.inspect_json(json.dumps(value).encode()))

    def test_bounded_traversal_and_static_errors(self):
        for body in (b'{"x":' + b'[' * 65 + b'0' + b']' * 65 + b'}',
                     b'{"x":[' + b'0,' * 32768 + b'0]}',
                     b'{"x":"\\ud800"}', b'{"x":1,"\\u0078":2}', b' ' * 1048577):
            with self.subTest(size=len(body)):
                with self.assertRaisesRegex(ValueError, '^(metrics_limit|invalid_json|body_limit)$'):
                    capture.structural_metrics(body)

    def test_numeric_tokens_and_schema_conventions(self):
        body = b'{"max_tokens":-0,"tools":[{"input_schema":{"x":[1.0,1e0,-0,9007199254740992,-9007199254740991,true,null]}}]}'
        result = capture.structural_metrics(body)
        self.assertEqual(result['max_tokens'], 'invalid')
        self.assertEqual(result['tools']['schema_noninteger_count'], 3)
        self.assertEqual(result['tools']['schema_unsafe_integer_count'], 1)
        self.assertEqual(result['tools']['schema_nodes_max'], 9)
        self.assertEqual(result['tools']['schema_depth_max'], 2)
        self.assertIn('schema_numeric_domain', result['mismatches'])
        for token in ('true', '1.0', '1e0', '-0', '9007199254740992'):
            r = capture.structural_metrics(('{"max_tokens":' + token + '}').encode())
            self.assertEqual(r['max_tokens'], 'invalid')

    def test_optional_presence_and_exact_schema_boundaries(self):
        empty = capture.structural_metrics(b'{}')
        self.assertEqual(empty['thinking_budget'], 'absent')
        self.assertEqual(empty['thinking'], 'absent')
        self.assertEqual(empty['effort'], 'absent')
        r = capture.structural_metrics(b'{"thinking":{"type":"adaptive","hidden":1},"output_config":{"effort":"high","hidden":1}}')
        self.assertEqual(r['thinking_unknown_field_count'], 1)
        self.assertEqual(r['output_unknown_field_count'], 1)
        for depth in (32, 33):
            schema = 0
            for _ in range(depth): schema = {'x': schema}
            r = capture.structural_metrics(json.dumps({'tools': [{'input_schema': schema}]}).encode())
            self.assertEqual(r['tools']['schema_depth_max'], depth)
            self.assertEqual('schema_depth' in r['mismatches'], depth > 32)
        for nodes in (8192, 8193):
            schema = {'x': [0] * (nodes - 2)}
            r = capture.structural_metrics(json.dumps({'tools': [{'input_schema': schema}]}).encode())
            self.assertEqual(r['tools']['schema_nodes_max'], nodes)
            self.assertEqual('schema_nodes' in r['mismatches'], nodes > 8192)
        for size in (65536, 65537):
            schema = {'x': 'a' * (size - 8)}
            r = capture.structural_metrics(json.dumps({'tools': [{'input_schema': schema}]}).encode())
            self.assertEqual(r['tools']['schema_bytes_max'], size)
            self.assertEqual('schema_bytes' in r['mismatches'], size > 65536)
        r = capture.structural_metrics(b'{' + b' ' * (capture.BODY_CAP - 2) + b'}')
        self.assertEqual(r['tools']['count'], 0)

    def test_closed_labels_utf8_presence_and_unknown_counts(self):
        canary = 'PRIVATE_LABEL'
        value = {'thinking': {'type': canary, 'effort': canary, canary: canary},
                 'output_config': {'effort': canary}, 'stream': canary,
                 'system': [{'type': canary, 'text': 'é', canary: canary}],
                 'tools': [{'name': canary, 'description': 'é', 'input_schema': {'type': canary}, canary: canary},
                           {'name': canary, 'input_schema': {}}], canary: canary}
        r = capture.structural_metrics(json.dumps(value).encode())
        self.assertEqual(r['thinking'], 'unknown')
        self.assertEqual(r['effort'], 'unknown')
        self.assertEqual(r['system']['type'], 'array')
        self.assertEqual(r['system']['count'], 1)
        self.assertEqual(r['system']['text_bytes'], 2)
        self.assertEqual(r['system']['unknown_type_count'], 1)
        self.assertEqual(r['system']['unknown_field_count'], 1)
        self.assertEqual(r['tools']['unknown_field_count'], 1)
        self.assertEqual(r['tools']['description_present'], 1)
        self.assertEqual(r['tools']['duplicate_name_count'], 1)
        self.assertEqual(r['tools']['name_max'], len(canary))
        self.assertEqual(r['tools']['description_max'], 2)
        self.assertNotIn(canary, json.dumps(r))
        def safe(x):
            if isinstance(x, dict):
                for v in x.values(): safe(v)
            elif isinstance(x, list):
                for v in x: safe(v)
            else: self.assertTrue(type(x) in (str, bool) or type(x) is int and 0 <= x <= 9007199254740991)
        safe(r)


from test_capture import TCPFixture, request


class OptInTests(TCPFixture):
    def test_default_unchanged_opt_in_metrics_static_503_and_bound(self):
        self.assertTrue(hasattr(self.server, 'structural_metrics_enabled'), 'explicit opt-in missing')
        body = b'{"stream":true,"max_tokens":32000,"messages":[],"tools":[]}'
        self.assertIn(b'503', self.exchange(request(body)))
        self.assertNotIn('metrics', self.server.records[-1])
        self.server.structural_metrics_enabled = True
        for _ in range(15):
            self.assertIn(b'503', self.exchange(request(body)))
        self.assertEqual(self.server.records[1]['metrics']['max_tokens'], 32000)
        self.assertLess(len(json.dumps(self.server.records, separators=(',', ':')).encode()), 16000)
        self.assertTrue(any(r.get('metrics_omitted') for r in self.server.records))

    def test_opt_in_metrics_obeys_original_lifetime(self):
        from unittest.mock import patch
        self.server.structural_metrics_enabled = True
        original = capture.structural_metrics
        def expire(body):
            result = original(body)
            self.server.lifetime_deadline = 0
            return result
        with patch.object(capture, 'structural_metrics', expire):
            self.assertIn(b'408', self.exchange(request(b'{"stream":true}')))
        self.assertEqual(self.server.records, [{'status': 408}])

    def test_explicit_entrypoint_and_image_hook(self):
        import pathlib, subprocess, sys
        root = pathlib.Path(__file__).resolve().parents[2]
        r = subprocess.run([sys.executable, '-B', str(root / 'Tools/AgentProtocolProbe/capture.py'),
                            '--duration', '1', '--structural-metrics'], capture_output=True, timeout=5)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stderr, b'')
        self.assertEqual(json.loads(r.stdout)['records'], [])
        builder = (root / 'Tools/AgentRuntime/build.py').read_text()
        supervisor = (root / 'Tools/AgentRuntime/agent_supervisor.py').read_text()
        self.assertIn('--structural-metrics', builder)
        self.assertIn('/runtime/structural-metrics-v1', supervisor)


if __name__ == '__main__':
    unittest.main()
