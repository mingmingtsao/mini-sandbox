"""Coding profile availability is not an authorization grant."""

import importlib.util
import inspect
import json
import pathlib
import subprocess
import sys
import unittest
from test_capture import capture, TCPFixture, request

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROFILE = 'claude-broker-coding-v1'
TOOLS = 'Bash,Read,Edit,Write,Glob,Grep'


class CodingProfileTests(unittest.TestCase):
    def test_exact_availability_only_launch(self):
        path = ROOT / ('Tools/AgentProtocolProbe/' + PROFILE + '.json')
        self.assertTrue(path.is_file(), 'named coding profile missing')
        restricted = json.loads((ROOT / 'Tools/AgentProtocolProbe/claude-broker-restricted-v1.json').read_text())
        expected = dict(restricted, profile=PROFILE, argv=restricted['argv'] + ['--tools', TOOLS])
        self.assertEqual(json.loads(path.read_text()), expected)

    def test_closed_toolset_metrics_and_unchanged_default(self):
        self.assertIn(
            'coding_tools', inspect.signature(capture.structural_metrics).parameters, 'coding tool whitelist missing'
        )
        known = TOOLS.split(',')
        for extra in ([], ['EndConversation'], ['PRIVATE_UNKNOWN_TOOL'], [None], ['Bash']):
            value = {'tools': [{'name': n, 'description': 'x' * 4285, 'input_schema': {}} for n in known + extra]}
            body = json.dumps(value).encode()
            self.assertNotIn('coding_toolset', capture.structural_metrics(body))
            result = capture.structural_metrics(body, coding_tools=True)
            metrics = result['coding_toolset']
            self.assertEqual(
                set(metrics),
                {
                    'bash_count',
                    'read_count',
                    'edit_count',
                    'write_count',
                    'glob_count',
                    'grep_count',
                    'end_conversation_count',
                    'other_count',
                    'within_selected_set',
                    'all_six_present',
                },
            )
            self.assertTrue(metrics['all_six_present'])
            self.assertIs(metrics['within_selected_set'], not extra or extra[0] in ('EndConversation', 'Bash'))
            self.assertEqual(metrics['end_conversation_count'], int(extra == ['EndConversation']))
            self.assertEqual(result['tools']['description_max'], 4285)
            self.assertIn('tool_description_bytes', result['mismatches'])
            self.assertNotIn('PRIVATE_UNKNOWN_TOOL', json.dumps(result))
        malformed = capture.structural_metrics(b'{"tools":[null,{},7]}', coding_tools=True)['coding_toolset']
        self.assertEqual(malformed['other_count'], 3)
        self.assertFalse(malformed['within_selected_set'])
        self.assertFalse(malformed['all_six_present'])

    def test_guest_help_checks_tools_only_for_coding_profile(self):
        spec = importlib.util.spec_from_file_location(
            'coding_supervisor', ROOT / 'Tools/AgentRuntime/agent_supervisor.py'
        )
        assert spec is not None and spec.loader is not None
        supervisor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(supervisor)
        self.assertIn('coding', inspect.signature(supervisor.help_flags).parameters, 'coding help check missing')
        data = ' '.join(supervisor.FLAGS).encode()
        self.assertNotIn('--tools', supervisor.help_flags(data))
        self.assertFalse(supervisor.help_flags(data, coding=True)['--tools'])
        self.assertFalse(supervisor.help_flags(data + b' --toolsExtra --tools-more', coding=True)['--tools'])
        self.assertTrue(supervisor.help_flags(data + b' --tools <list>', coding=True)['--tools'])
        expected = json.loads((ROOT / ('Tools/AgentProtocolProbe/' + PROFILE + '.json')).read_text())['argv']
        self.assertTrue(supervisor.coding_argv_matches(expected))
        self.assertFalse(supervisor.coding_argv_matches(expected + ['--allowedTools', TOOLS]))
        self.assertFalse(supervisor.coding_argv_matches(expected[:-1] + ['Bash']))

    def test_explicit_builder_verifier_hooks_and_mutual_exclusion(self):
        for name in ('build.py', 'verify_agent_vm.py'):
            source = ROOT / 'Tools/AgentRuntime' / name
            self.assertIn('--claude-broker-coding-v1', source.read_text(), 'coding opt-in missing')
            args = [sys.executable, '-B', str(source), '/nonexistent', '/nonexistent', '/nonexistent']
            if name == 'verify_agent_vm.py':
                args.append('/nonexistent')
            result = subprocess.run(
                args + ['--claude-broker-coding-v1', '--claude-broker-restricted-v1'], capture_output=True, timeout=5
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'profiles are mutually exclusive', result.stderr)
        source = (ROOT / 'Tools/AgentRuntime/agent_supervisor.py').read_text()
        self.assertIn('--coding-profile', source)


class CodingCaptureTests(TCPFixture):
    def test_real_tcp_opt_in_privacy_retention_and_profile_exclusion(self):
        self.assertTrue(hasattr(self.server, 'coding_profile'), 'coding capture hook missing')
        with self.assertRaisesRegex(ValueError, '^coding_profile_requires_metrics$'):
            capture.CaptureServer(('127.0.0.1', 0), coding_profile=True)
        with self.assertRaisesRegex(ValueError, '^profiles_are_mutually_exclusive$'):
            capture.CaptureServer(
                ('127.0.0.1', 0), structural_metrics_enabled=True, coding_profile=True, restricted_profile=True
            )
        self.server.structural_metrics_enabled = True
        self.server.coding_profile = True
        body = json.dumps(
            {
                'model': 'deepseek-flash',
                'max_tokens': 8192,
                'tools': [{'name': n} for n in TOOLS.split(',')] + [{'name': 'PRIVATE_CANARY'}],
            }
        ).encode()
        for _ in range(16):
            self.assertIn(b'503', self.exchange(request(body)))
        record = self.server.records[0]
        self.assertTrue(record['metrics']['model_matches_profile'])
        self.assertFalse(record['anthropic_beta_present'])
        self.assertEqual(record['metrics']['coding_toolset']['other_count'], 1)
        self.assertNotIn('PRIVATE_CANARY', json.dumps(self.server.records))
        self.assertLess(len(json.dumps(self.server.records, separators=(',', ':')).encode()), 16000)
        self.assertTrue(any(r.get('metrics_omitted') for r in self.server.records))


if __name__ == '__main__':
    unittest.main()
