import hashlib
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROFILE = 'claude-broker-restricted-v1'


class RestrictedProfileTests(unittest.TestCase):
    def test_explicit_profile_exact_launch_and_replacement_environment(self):
        stock_path = ROOT / 'Tools/AgentProtocolProbe/guest-launch.json'
        self.assertEqual(
            hashlib.sha256(stock_path.read_bytes()).hexdigest(),
            '74e02d07a0456cd2c864f33b5bc7f825412e2bc40e38cec786c5159c9a910ebc',
        )
        path = ROOT / ('Tools/AgentProtocolProbe/' + PROFILE + '.json')
        self.assertTrue(path.is_file(), 'named restricted launch profile missing')
        stock = json.loads(stock_path.read_text())
        expected = json.loads(stock_path.read_text())
        expected['profile'] = PROFILE
        expected['argv'][-1] = 'deepseek-flash'
        expected['environment'].update(
            {
                'CLAUDE_CODE_MAX_OUTPUT_TOKENS': '8192',
                'CLAUDE_CODE_DISABLE_THINKING': '1',
                'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS': '1',
            }
        )
        actual = json.loads(path.read_text())
        self.assertEqual(actual, expected)
        self.assertEqual(actual['stdin_fixed_utf8'], stock['stdin_fixed_utf8'])
        self.assertEqual(actual['environment_mode'], 'replace-not-inherit')
        self.assertEqual(
            set(actual['environment']) - set(stock['environment']),
            {'CLAUDE_CODE_MAX_OUTPUT_TOKENS', 'CLAUDE_CODE_DISABLE_THINKING', 'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS'},
        )

    def test_expected_model_is_fixed_bool_not_raw_value(self):
        import inspect
        from test_capture import capture

        self.assertIn(
            'expected_model',
            inspect.signature(capture.structural_metrics).parameters,
            'trusted expected model comparison missing',
        )
        for model in ('deepseek-flash', 'PRIVATE_MODEL_CANARY', None, 7):
            result = capture.structural_metrics(json.dumps({'model': model}).encode(), expected_model='deepseek-flash')
            self.assertIs(result['model_matches_profile'], model == 'deepseek-flash')
            self.assertNotIn('PRIVATE_MODEL_CANARY', json.dumps(result))
        self.assertFalse(capture.structural_metrics(b'{}', expected_model='deepseek-flash')['model_matches_profile'])
        self.assertNotIn('model_matches_profile', capture.structural_metrics(b'{}'))
        with self.assertRaisesRegex(ValueError, '^unsupported_profile$'):
            capture.structural_metrics(b'{}', expected_model='PRIVATE_MODEL_CANARY')

    def test_explicit_builder_supervisor_and_verifier_hook(self):
        builder = (ROOT / 'Tools/AgentRuntime/build.py').read_text()
        supervisor = (ROOT / 'Tools/AgentRuntime/agent_supervisor.py').read_text()
        verifier = (ROOT / 'Tools/AgentRuntime/verify_agent_vm.py').read_text()
        self.assertIn('--claude-broker-restricted-v1', builder)
        self.assertIn('claude-broker-restricted-v1.json', builder)
        self.assertIn('claude-broker-restricted-v1', supervisor)
        self.assertIn('--restricted-profile', supervisor)
        self.assertIn('--claude-broker-restricted-v1', verifier)


from test_capture import TCPFixture, request, capture


class RestrictedCaptureTests(TCPFixture):
    def test_opt_in_real_tcp_bool_and_beta_presence_no_raw_model(self):
        self.assertTrue(hasattr(self.server, 'restricted_profile'), 'restricted capture hook missing')
        self.server.structural_metrics_enabled = True
        self.server.restricted_profile = True
        for model in ('deepseek-flash', 'PRIVATE_MODEL_CANARY'):
            body = json.dumps({'model': model, 'max_tokens': 8192}).encode()
            self.assertIn(b'503', self.exchange(request(body)))
            record = self.server.records[-1]
            self.assertIs(record['metrics']['model_matches_profile'], model == 'deepseek-flash')
            self.assertIs(record['anthropic_beta_present'], False)
            self.assertNotIn('PRIVATE_MODEL_CANARY', json.dumps(record))
        with self.assertRaisesRegex(ValueError, '^restricted_profile_requires_metrics$'):
            capture.CaptureServer(('127.0.0.1', 0), restricted_profile=True)


if __name__ == '__main__':
    unittest.main()
