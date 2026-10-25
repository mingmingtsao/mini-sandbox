import pathlib, unittest, importlib.util, os, subprocess, sys
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[2]
class SupervisorTests(unittest.TestCase):
    def test_only_whitelisted_metadata_and_fixed_profile(self):
        path=ROOT/'Tools/AgentRuntime/agent_supervisor.py'
        self.assertTrue(path.exists(),'trusted bounded guest supervisor missing')
        spec=importlib.util.spec_from_file_location('agent_supervisor',path)
        m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        self.assertEqual(m.help_flags(b'--print --no-session-persistence --setting-sources --strict-mcp-config --mcp-config --model SECRET'),{k:True for k in m.FLAGS})
        self.assertFalse(any(m.help_flags(b'SECRET').values()))
        self.assertTrue(m.version_match(b'2.1.309 (Claude Code)\n'))
        self.assertFalse(m.version_match(b'2.1.309 malicious'))
        self.assertEqual(m.PROFILE,'pinned-cli-local-capture-v1')
        self.assertEqual(m.COMMAND_SECONDS,55)
    def test_help_flags_must_be_tokens_not_substrings(self):
        spec=importlib.util.spec_from_file_location('agent_supervisor',ROOT/'Tools/AgentRuntime/agent_supervisor.py')
        m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        self.assertFalse(m.help_flags(b'--printing --model-extra --mcp-config-extra')['--print'])
        self.assertFalse(m.help_flags(b'--model-extra')['--model'])
    def test_profile_is_explicit_in_image_builder(self):
        source=(ROOT/'Tools/AgentRuntime/build.py').read_text()
        self.assertIn("manifest['agentProbeProfile']",source)
    def test_capture_has_separate_process_and_bounded_output(self):
        source=(ROOT/'Tools/AgentRuntime/agent_supervisor.py').read_text()
        self.assertIn('def capture_worker(',source)
        self.assertIn('captureEnd=time.monotonic()+37',source)
        self.assertIn("'--capture'",source)
        self.assertIn("raise ValueError('capture output bound')",source)
    @unittest.skipUnless(sys.platform=='linux','Linux group semantics; exercised by real guest supervisor_check.py')
    def test_real_output_bound_and_stubborn_owned_cleanup(self):
        spec=importlib.util.spec_from_file_location('agent_supervisor',ROOT/'Tools/AgentRuntime/agent_supervisor.py')
        m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        actual=subprocess.Popen;children=[]
        def launch(*args,**kwargs):
            p=actual(*args,**kwargs);children.append(p);return p
        with patch.object(m.subprocess,'Popen',launch):
            with self.assertRaises(ValueError):m.bounded_output([sys.executable,'-c','print("X"*70000)'],{},str(ROOT),1)
            with self.assertRaises(TimeoutError):m.bounded_output([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)'],{},str(ROOT),.2)
        self.assertEqual(children[-1].returncode,-9)
        for child in children:
            self.assertIsNotNone(child.returncode)
            with self.assertRaises(ProcessLookupError):os.killpg(child.pid,0)
