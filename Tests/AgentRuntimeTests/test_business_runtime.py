"""Business guest boundary checks. No vendor CLI or imported code is executed."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools/AgentRuntime'))
import business_cli as cli
import business_workspace as workspace
import workspace_data as wire


class Channel:
    def __init__(self, frames):
        self.frames = iter(frames)
        self.sent = []

    def receive(self):
        return next(self.frames)

    def send(self, frame):
        self.sent.append(frame)


def frames(files):
    channel = Channel([])
    workspace.send_workspace(channel, files)
    return channel.sent


class BusinessRuntimeTests(unittest.TestCase):
    def test_start_requires_exact_typed_host_shape_and_bounded_task(self):
        valid = dict(v=1, type='start', task='Read the project and run its tests.', mcp=False)
        self.assertEqual(cli.validate_start(valid), valid)
        for change in ({'v': True}, {'v': 2}, {'mcp': 1}, {'task': ''}, {'task': 'x' * 8193}, {'runID': 'forged'}, {'upstream': 'http://elsewhere'}):
            with self.subTest(change=list(change)), self.assertRaises(ValueError):
                cli.validate_start(dict(valid, **change))

    def test_permission_roundtrip_preserves_exact_cli_input_and_request_id(self):
        request = {'type': 'control_request', 'request_id': 'request-1', 'request':
                   {'subtype': 'can_use_tool', 'tool_name': 'Edit', 'tool_use_id': 'tool-1',
                    'input': {'file_path': '/work/project/logic.py', 'old_string': '-', 'new_string': '+'}}}
        response = cli.permission_reply(request, {'behavior': 'allow', 'updatedInput': request['request']['input']})
        self.assertEqual(response['response']['request_id'], 'request-1')
        self.assertEqual(response['response']['response']['updatedInput'], request['request']['input'])
        with self.assertRaises(ValueError):
            cli.permission_reply(request, {'behavior': 'allow', 'updatedInput': {'file_path': '/elsewhere'}})
        with self.assertRaises(ValueError):
            cli.permission_reply(request, {'behavior': 'allow', 'updatedInput': request['request']['input'], 'permissionMode': 'bypassPermissions'})
        denied = cli.permission_reply(request, {'behavior': 'deny', 'message': 'Denied by host'})
        self.assertEqual(denied['response']['response']['behavior'], 'deny')

    def test_workspace_roundtrip_never_edits_or_executes_imported_files(self):
        files = {'logic.py': b'def add(a, b):\n    return a - b\n', 'nested/data.bin': bytes(range(256)) * 32}
        channel = Channel(frames(files))
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'project'
            with mock.patch.object(workspace, 'ROOT', target), mock.patch.object(wire, 'ROOT', target), \
                    mock.patch.object(cli.subprocess, 'run', side_effect=AssertionError('harness executed code')):
                self.assertEqual(workspace.receive_workspace(channel), wire.treehash(files))
                self.assertEqual(wire.snapshot(), files)
            self.assertEqual(channel.sent[0], dict(v=1, type='ready'))
            self.assertEqual(channel.sent[-1], dict(v=1, type='ack', seq=len(frames(files)) - 1))

    def test_workspace_rejects_traversal_wrong_digest_and_replay_before_materialization(self):
        originals = frames({'logic.py': b'x'})
        invalid = []
        for index, update in [(1, {'path': '../escape'}), (1, {'sha256': '0' * 64}), (2, {'offset': 1}), (3, {'seq': 0})]:
            candidate = [dict(frame) for frame in originals]
            candidate[index].update(update); invalid.append(candidate)
        for candidate in invalid:
            with tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / 'project'
                with mock.patch.object(workspace, 'ROOT', target), self.assertRaises((ValueError, StopIteration)):
                    workspace.receive_workspace(Channel(candidate))
                self.assertFalse(target.exists())

    def test_result_refuses_links_and_unrepresentable_empty_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            with mock.patch.object(workspace, 'ROOT', target), mock.patch.object(wire, 'ROOT', target):
                (target / 'empty').mkdir()
                with self.assertRaises(ValueError): workspace.frozen_result()
                (target / 'empty').rmdir()
                (target / 'link').symlink_to('/etc/passwd')
                with self.assertRaises(ValueError): workspace.frozen_result()

    def test_business_profile_is_separate_from_diagnostic_flags(self):
        spec = importlib.util.spec_from_file_location('business_builder', ROOT / 'Tools/AgentRuntime/build.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        for flags in (['--claude-business-runtime-v1', '--workspace'], ['--agent-probe', '--claude-business-runtime-v1'], ['--claude-business-runtime-v1', '--structural-metrics']):
            with mock.patch.object(sys, 'argv', ['build', 'cache', 'base', 'out', *flags]), \
                    mock.patch.object(builder.image.legacy, 'reserve_output', side_effect=AssertionError('reserved output')), self.assertRaises(ValueError):
                builder.main()


if __name__ == '__main__':
    unittest.main()
