"""Actual guest CLI with normal stream-json permission decisions from the host.

Only the CLI edits the imported project and runs its tools. This driver neither
creates tool_result messages nor treats a model/CLI success string as acceptance.
"""
import base64
import ctypes
import hashlib
import json
import os
import pathlib
import resource
import selectors
import socket
import subprocess
import sys
import threading
import time
import agent_supervisor as owned
from business_workspace import FramedSocket, ROOT, receive_workspace, frozen_result, send_workspace
import workspace_data as wire

PROFILE = 'claude-business-runtime-v1'


def validate_start(request):
    if type(request) is not dict or set(request) != {'v', 'type', 'task', 'mcp'} or type(request['v']) is not int or request['v'] != 1 or request['type'] != 'start' or type(request['mcp']) is not bool:
        raise ValueError('start envelope')
    if not isinstance(request['task'], str) or not 1 <= len(request['task'].encode()) <= 8192:
        raise ValueError('task bound')
    return request


def limits():
    resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
    resource.setrlimit(resource.RLIMIT_FSIZE, (67108864, 67108864))
    resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def permission_reply(message, decision):
    if message.get('type') != 'control_request' or not isinstance(message.get('request_id'), str):
        raise ValueError('control envelope')
    request = message.get('request', {})
    if request.get('subtype') != 'can_use_tool' or not isinstance(request.get('input'), dict):
        raise ValueError('unsupported control request')
    if decision.get('behavior') == 'allow':
        if set(decision) != {'behavior', 'updatedInput'} or decision['updatedInput'] != request['input']:
            raise ValueError('host altered permission input')
    elif decision.get('behavior') == 'deny':
        if set(decision) != {'behavior', 'message'} or not isinstance(decision['message'], str):
            raise ValueError('host denial')
    else:
        raise ValueError('host decision')
    return {'type': 'control_response', 'response': {'subtype': 'success', 'request_id': message['request_id'], 'response': decision}}


def host_decision(message, deadline):
    body = json.dumps(message, separators=(',', ':')).encode()
    if len(body) > 16384:
        raise ValueError('permission bound')
    decision_deadline = min(deadline, time.monotonic() + 300)
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as peer:
        peer.settimeout(1); peer.connect((2, 4065))
        peer.sendall(len(body).to_bytes(4, 'big') + body)
        result = bytearray()
        while time.monotonic() < decision_deadline:
            try:
                part = peer.recv(min(4096, 16385 - len(result)))
            except socket.timeout:
                continue
            if not part:
                return json.loads(result, object_pairs_hook=wire.pairs)
            result.extend(part)
            if len(result) > 16384:
                raise ValueError('permission reply bound')
    raise TimeoutError('permission decision deadline')


def proxy_connection(client, port, deadline):
    with client, socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as peer:
        peer.settimeout(1); peer.connect((2, port))
        client.setblocking(False); peer.setblocking(False)
        selector = selectors.DefaultSelector()
        queues = {client: bytearray(), peer: bytearray()}
        totals = {client: 0, peer: 0}
        targets = {client: peer, peer: client}
        eof = set()
        try:
            selector.register(client, selectors.EVENT_READ)
            selector.register(peer, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                for key, mask in selector.select(.05):
                    source = key.fileobj; target = targets[source]
                    if mask & selectors.EVENT_WRITE:
                        try:
                            count = source.send(queues[source][:16384])
                            if count <= 0:
                                raise OSError('proxy write closed')
                            del queues[source][:count]
                        except (BlockingIOError, InterruptedError):
                            pass
                    if mask & selectors.EVENT_READ:
                        try:
                            data = source.recv(4096)
                        except (BlockingIOError, InterruptedError):
                            data = None
                        if data == b'':
                            eof.add(source)
                        elif data:
                            totals[source] += len(data)
                            maximum = 81920 if source is client else 8388608
                            if totals[source] > maximum or len(queues[target]) + len(data) > 32768:
                                raise ValueError('proxy byte bound')
                            queues[target].extend(data)
                if peer in eof and not queues[client]:
                    return
                if client in eof and not queues[peer]:
                    # Preserve response delivery after a client's write half-close.
                    try:
                        peer.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                for source in (client, peer):
                    target = targets[source]
                    events = 0
                    if source not in eof and len(queues[target]) <= 28672:
                        events |= selectors.EVENT_READ
                    if queues[source]:
                        events |= selectors.EVENT_WRITE
                    registered = source.fileno() in selector.get_map()
                    if registered and events:
                        selector.modify(source, events)
                    elif registered:
                        selector.unregister(source)
                    elif events:
                        selector.register(source, events)
            raise TimeoutError('proxy deadline')
        finally:
            selector.close()


def proxy(mcp=False):
    deadline = time.monotonic() + 855
    workers = []
    servers = []
    selector = selectors.DefaultSelector()
    slots = threading.BoundedSemaphore(2)
    count = 0
    def worker(client, port):
        try:
            proxy_connection(client, port, deadline)
        except Exception:
            pass  # The closed connection is the only error path; no fake HTTP.
        finally:
            slots.release()
    try:
        for local, remote in [(4061, 4064)] + ([(4063, 4066)] if mcp else []):
            server = socket.socket(); server.bind(('127.0.0.1', local)); server.listen(2); server.setblocking(False)
            servers.append(server); selector.register(server, selectors.EVENT_READ, remote)
        print('ready', flush=True)
        while time.monotonic() < deadline and count < 64:
            for key, _ in selector.select(.1):
                client, _ = key.fileobj.accept()
                if not slots.acquire(blocking=False):
                    client.close(); continue
                count += 1
                thread = threading.Thread(target=worker, args=(client, key.data), daemon=True)
                thread.start(); workers.append(thread)
            workers = [thread for thread in workers if thread.is_alive()]
    finally:
        selector.close()
        for server in servers:
            server.close()
        for thread in workers:
            thread.join(timeout=.1)


def write_cli(process, value, deadline):
    body = memoryview(json.dumps(value, separators=(',', ':')).encode() + b'\n')
    if len(body) > 16384:
        raise ValueError('CLI control bound')
    while body and time.monotonic() < deadline:
        try:
            count = os.write(process.stdin.fileno(), body)
            if count <= 0:
                raise OSError('CLI input closed')
            body = body[count:]
        except (BlockingIOError, InterruptedError):
            time.sleep(.005)
    if body:
        raise TimeoutError('CLI control deadline')


def run_cli(plan, request, control, deadline):
    for name in ('business-home', 'business-tmp', 'business-check-home', 'business-check-tmp'):
        os.mkdir('/run/agent-probe/' + name, 0o700)
    env = dict(plan['environment'])
    checkenv = dict(env, HOME='/run/agent-probe/business-check-home', TMPDIR='/run/agent-probe/business-check-tmp')
    code, version = owned.bounded_output([plan['binary'], '--version'], checkenv, str(ROOT))
    if code or not owned.version_match(version):
        raise ValueError('CLI version mismatch')
    proxy_process = subprocess.Popen(['/usr/bin/python3', '-B', __file__, '--proxy'] + (['--mcp'] if request['mcp'] else []),
        env={'PATH': '/usr/bin:/bin', 'PYTHONDONTWRITEBYTECODE': '1'}, cwd='/runtime', stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True, preexec_fn=limits)
    process = None
    selector = selectors.DefaultSelector()
    result = None; initialized = False; total = 0; permissions = 0; buffer = bytearray()
    try:
        selector.register(proxy_process.stdout, selectors.EVENT_READ)
        if not selector.select(2) or os.read(proxy_process.stdout.fileno(), 64) != b'ready\n':
            raise RuntimeError('proxy startup')
        selector.unregister(proxy_process.stdout)
        mcp = {'mcpServers': {'sandbox': {'type': 'http', 'url': 'http://127.0.0.1:4063/mcp'}}} if request['mcp'] else {'mcpServers': {}}
        argv = plan['argv'] + ['--strict-mcp-config', '--mcp-config', json.dumps(mcp, separators=(',', ':'))]
        process = subprocess.Popen(argv, env=env, cwd=str(ROOT), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True, preexec_fn=limits)
        os.set_blocking(process.stdin.fileno(), False)
        for stream, label in ((process.stdout, 'stdout'), (process.stderr, 'stderr')):
            os.set_blocking(stream.fileno(), False); selector.register(stream, selectors.EVENT_READ, label)
        write_cli(process, {'type': 'control_request', 'request_id': 'sandbox-init', 'request': {'subtype': 'initialize'}}, min(deadline, time.monotonic() + 3))
        while selector.get_map() and time.monotonic() < deadline:
            for key, _ in selector.select(.05):
                data = os.read(key.fd, 4096)
                if not data:
                    selector.unregister(key.fileobj); continue
                total += len(data)
                if total > plan['limits']['cli_output_bytes']:
                    raise ValueError('CLI output bound')
                control.send({'v': 1, 'type': 'output', 'channel': key.data,
                              'data': base64.b64encode(data).decode(), 'sha256': wire.sha(data)})
                if key.data == 'stderr':
                    continue
                buffer.extend(data)
                if len(buffer) > 65536:
                    raise ValueError('CLI line bound')
                while b'\n' in buffer:
                    line, _, rest = buffer.partition(b'\n'); buffer[:] = rest
                    message = json.loads(line, object_pairs_hook=wire.pairs)
                    if message.get('type') == 'control_response':
                        response = message.get('response', {})
                        if initialized or response.get('request_id') != 'sandbox-init' or response.get('subtype') != 'success':
                            raise ValueError('initialize response')
                        initialized = True
                        write_cli(process, {'type': 'user', 'message': {'role': 'user', 'content': request['task']},
                                  'parent_tool_use_id': None, 'session_id': ''}, min(deadline, time.monotonic() + 3))
                    elif message.get('type') == 'control_request':
                        permissions += 1
                        if permissions > plan['limits']['permission_requests']:
                            raise ValueError('permission count bound')
                        reply = permission_reply(message, host_decision(message, deadline))
                        write_cli(process, reply, min(deadline, time.monotonic() + 3))
                    elif message.get('type') == 'result':
                        if result is not None:
                            raise ValueError('duplicate result')
                        result = message; process.stdin.close()
            if result is not None and process.poll() is not None:
                break
        if buffer:
            raise ValueError('incomplete CLI event')
        timed_out = process.poll() is None
        owned.cleanup(process)
        return dict(exit=process.returncode, initialized=initialized, isError=(result is None or result.get('is_error', True)),
                    outputBytes=total, permissions=permissions, timedOut=timed_out)
    finally:
        if process is not None:
            owned.cleanup(process)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()
        owned.cleanup(proxy_process); proxy_process.stdout.close(); selector.close()


def main():
    if ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) != 0:
        raise RuntimeError('subreaper')
    plan = json.loads(pathlib.Path('/runtime/business-launch.json').read_text(), object_pairs_hook=wire.pairs)
    if plan['profile'] != PROFILE or owned.hashed(plan['binary']) != plan['binary_sha256'] or plan['binary_sha256'] != owned.SHA:
        raise ValueError('profile identity')
    if os.listdir('/sys/class/net') != ['lo'] or len(pathlib.Path('/proc/net/route').read_text().splitlines()) != 1:
        raise ValueError('network configuration')
    deadline = time.monotonic() + 855
    control = FramedSocket(4060, deadline)
    workspace = None
    try:
        control.send({'v': 1, 'type': 'ready', 'profile': PROFILE})
        request = validate_start(control.receive())
        workspace = FramedSocket(4062, deadline)
        receive_workspace(workspace)
        result = run_cli(plan, request, control, min(deadline, time.monotonic() + plan['wall_timeout_seconds']))
        # No CLI writer survives normal owned group cleanup. Mount-wide RO is
        # an additional seal; the host still treats all guest data as untrusted.
        subprocess.run(['/bin/busybox', 'mount', '-o', 'remount,ro', '/work'], check=True,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        files = frozen_result()
        control.send(dict(v=1, type='finished', workspaceSHA256=wire.treehash(files), **result))
        send_workspace(workspace, files)
        # Host closes the channels and actually stops the machine before adoption.
        try:
            control.exact(1)
        except (EOFError, TimeoutError, OSError):
            pass
    finally:
        if workspace is not None:
            workspace.close()
        control.close()


if __name__ == '__main__':
    if sys.argv[1:2] == ['--proxy']:
        proxy('--mcp' in sys.argv[2:])
    else:
        try:
            main()
        except Exception as error:
            # Static failure category only; no request/credential/path echo.
            print('BUSINESS_RUNTIME_FAILED:' + type(error).__name__, flush=True)
            raise SystemExit(1)
