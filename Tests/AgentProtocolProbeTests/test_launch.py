import json
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class LaunchTests(unittest.TestCase):
    def test_guest_launch_description_is_fixed_not_execution(self):
        plan = json.loads((ROOT / 'Tools/AgentProtocolProbe/guest-launch.json').read_text())
        self.assertEqual(plan['status'], 'NOT_RUN')
        self.assertEqual(plan['platform'], 'linux-aarch64')
        env, args = plan['environment'], plan['argv']
        self.assertEqual(plan['environment_mode'], 'replace-not-inherit')
        self.assertEqual(env['ANTHROPIC_BASE_URL'], 'http://127.0.0.1:4061')
        self.assertEqual(env['DISABLE_AUTOUPDATER'], '1')
        self.assertEqual(env['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'], '1')
        self.assertIn('--no-session-persistence', args)
        self.assertNotIn('HTTPS_PROXY', env)
        self.assertNotIn('--dangerously-skip-permissions', args)
        self.assertTrue(plan['no_forwarding'])

    def test_exact_proposed_argv_environment_and_owned_cleanup(self):
        plan = json.loads((ROOT / 'Tools/AgentProtocolProbe/guest-launch.json').read_text())
        self.assertEqual(
            plan['argv'],
            [
                '/opt/agent-probe/claude',
                '--print',
                '--no-session-persistence',
                '--setting-sources',
                '',
                '--strict-mcp-config',
                '--mcp-config',
                '{"mcpServers":{}}',
                '--model',
                'deepseek-chat',
            ],
        )
        self.assertEqual(plan['environment_mode'], 'replace-not-inherit')
        self.assertEqual(
            plan['environment'],
            {
                'HOME': '/run/agent-probe/home',
                'TMPDIR': '/run/agent-probe/tmp',
                'PATH': '/usr/bin:/bin',
                'LANG': 'C.UTF-8',
                'ANTHROPIC_BASE_URL': 'http://127.0.0.1:4061',
                'ANTHROPIC_AUTH_TOKEN': 'probe-only-not-a-credential',
                'DISABLE_AUTOUPDATER': '1',
                'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
                'CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL': '1',
            },
        )
        self.assertEqual((plan['stdout'], plan['stderr']), ('/dev/null', '/dev/null'))
        self.assertEqual(plan['stdin_fixed_utf8'], 'Reply with OK. Do not run tools.\n')
        self.assertEqual(plan['cwd'], '/run/agent-probe/work')
        self.assertEqual(plan['wall_timeout_seconds'], 30)
        self.assertEqual(
            plan['cancel'],
            {
                'target': 'owned process group only',
                'signal': 'SIGTERM',
                'grace_seconds': 2,
                'fallback': 'SIGKILL',
                'evidence': 'exit status and metadata count only; not upstream cancellation proof',
            },
        )
        self.assertEqual(
            plan['capture'],
            {
                'command': ['python3', '-B', '/opt/agent-probe/capture.py'],
                'bind': '127.0.0.1:4061',
                'lifetime_seconds': 35,
                'output': 'metadata-only JSON to runtime control; never raw CLI output',
            },
        )
        self.assertEqual(plan['status'], 'NOT_RUN')
        self.assertTrue(plan['no_provider_success_emulation'])

    def test_populated_entrypoint_stdout_and_stderr_are_private(self):
        import os
        import select
        import socket

        read_fd, ready_fd = os.pipe()
        bootstrap = '''import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('capture', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original = module.CaptureServer
ready_fd = int(sys.argv[2])
def ready_server(*args, **kwargs):
    server = original(('127.0.0.1', 0), **kwargs)
    os.write(ready_fd, str(server.server_address[1]).encode() + b'\\n')
    os.close(ready_fd)
    return server
module.CaptureServer = ready_server
sys.argv = ['capture', '--duration', '1']
raise SystemExit(module.main())
'''
        child = subprocess.Popen(
            [sys.executable, '-B', '-c', bootstrap, str(ROOT / 'Tools/AgentProtocolProbe/capture.py'), str(ready_fd)],
            pass_fds=(ready_fd,),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        os.close(ready_fd)
        try:
            self.assertTrue(select.select([read_fd], [], [], 2)[0], 'capture readiness missing')
            port = int(os.read(read_fd, 64))
            body = b'{"model":"PROMPT_CANARY","UNKNOWN_CANARY":"TOKEN_CANARY"}'
            wire = (
                b'POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAuthorization: Bearer TOKEN_CANARY\r\nContent-Length: '
                + str(len(body)).encode()
                + b'\r\n\r\n'
                + body
            )
            with socket.create_connection(('127.0.0.1', port), timeout=2) as client:
                client.sendall(wire)
                client.shutdown(socket.SHUT_WR)
                self.assertIn(b'503', client.recv(4096))
            stdout, stderr = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 0)
            self.assertEqual(stderr, b'')
            data = json.loads(stdout)
            self.assertEqual(len(data['records']), 1)
            self.assertEqual(data['records'][0]['status'], 503)
            for marker in (b'PROMPT_CANARY', b'TOKEN_CANARY', b'UNKNOWN_CANARY', b'Traceback'):
                self.assertNotIn(marker, stdout + stderr)
        finally:
            os.close(read_fd)
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=2)

    def test_capture_entrypoint_real_process(self):
        result = subprocess.run(
            [sys.executable, '-B', str(ROOT / 'Tools/AgentProtocolProbe/capture.py'), '--duration', '1'],
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith(b'{'), 'executable capture entrypoint missing')
        self.assertEqual(json.loads(result.stdout)['records'], [])
        self.assertEqual(result.stderr, b'')
