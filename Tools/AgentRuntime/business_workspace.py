"""Guest-only bounded workspace copy; no fixture task or host execution."""

import base64
import json
import os
import pathlib
import socket
import struct
import time
import workspace_data as wire

ROOT = pathlib.Path('/work/project')
wire.ROOT = ROOT


class FramedSocket:
    def __init__(self, port, deadline, maximum=16384):
        self.peer = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        self.peer.settimeout(1)
        self.deadline = deadline
        self.maximum = maximum
        self.peer.connect((2, port))

    def close(self):
        self.peer.close()

    def send(self, value):
        body = json.dumps(value, separators=(',', ':'), sort_keys=True).encode()
        if not 0 < len(body) <= self.maximum or time.monotonic() >= self.deadline:
            raise ValueError('frame bound')
        self.peer.sendall(struct.pack('>I', len(body)) + body)

    def exact(self, count):
        result = bytearray()
        while len(result) < count:
            if time.monotonic() >= self.deadline:
                raise TimeoutError('channel deadline')
            try:
                data = self.peer.recv(min(4096, count - len(result)))
            except socket.timeout:
                continue
            if not data:
                raise EOFError('channel closed')
            result.extend(data)
        return bytes(result)

    def receive(self):
        length = struct.unpack('>I', self.exact(4))[0]
        if not 0 < length <= self.maximum:
            raise ValueError('frame bound')
        return json.loads(
            self.exact(length), object_pairs_hook=wire.pairs, parse_float=wire.no_float, parse_constant=wire.no_float
        )


def receive_workspace(channel):
    if ROOT.exists() and list(ROOT.iterdir()):
        raise ValueError('workspace must be fresh')
    files, names = {}, {}
    seq = 0
    current = count = total = None
    received = 0
    channel.send(dict(v=1, type='ready'))
    while True:
        value = channel.receive()
        if (
            type(value) is not dict
            or wire.integer(value.get('v'), 1) != 1
            or wire.integer(value.get('seq'), 8191) != seq
        ):
            raise ValueError('sequence')
        kind = value.get('type')
        fields = {
            'begin': {'count', 'total'},
            'file': {'path', 'size', 'sha256'},
            'chunk': {'offset', 'data'},
            'end': set(),
            'complete': {'sha256'},
        }
        if kind not in fields or set(value) != fields[kind] | {'v', 'type', 'seq'}:
            raise ValueError('fields')
        if kind == 'begin':
            if count is not None:
                raise ValueError('begin order')
            count = wire.integer(value['count'], 1000)
            total = wire.integer(value['total'], wire.MAX_TOTAL)
        elif kind == 'file':
            if count is None or current is not None or len(files) >= count:
                raise ValueError('file order')
            parts = wire.pathcheck(value['path'])
            prefix = ''
            for index, part in enumerate(parts):
                prefix = part if not prefix else prefix + '/' + part
                folded = prefix.casefold()
                if folded in names and (names[folded] != prefix or index == len(parts) - 1 or prefix in files):
                    raise ValueError('path collision')
                names[folded] = prefix
            if len(names) > 1000:
                raise ValueError('entry bound')
            size = wire.integer(value['size'], wire.MAX_FILE)
            if size > total - received:
                raise ValueError('total bound')
            current = value['path']
            digest = value['sha256']
            data = bytearray()
        elif kind == 'chunk':
            if current is None or wire.integer(value['offset'], wire.MAX_FILE) != len(data):
                raise ValueError('chunk order')
            chunk = base64.b64decode(value['data'], validate=True)
            if not 0 < len(chunk) <= 4096 or len(chunk) > size - len(data):
                raise ValueError('chunk bound')
            data.extend(chunk)
        elif kind == 'end':
            if current is None or len(data) != size or wire.sha(data) != digest:
                raise ValueError('file digest')
            files[current] = bytes(data)
            received += len(data)
            current = None
        elif kind == 'complete':
            if (
                current is not None
                or count != len(files)
                or received != total
                or wire.treehash(files) != value['sha256']
            ):
                raise ValueError('tree digest')
        channel.send(dict(v=1, type='ack', seq=seq))
        seq += 1
        if kind == 'complete':
            break
    ROOT.mkdir(mode=0o700, exist_ok=True)
    for path, data in sorted(files.items()):
        target = ROOT / path
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
    return wire.treehash(files)


def frozen_result():
    # Called after owned CLI/proxy process groups are reaped and /work is
    # remounted read-only. Guest reporting is untrusted, never host attestation.
    for directory, dirs, leaves in os.walk(ROOT, followlinks=False):
        if pathlib.Path(directory) != ROOT and not dirs and not leaves:
            raise ValueError('empty directory transport unsupported')
    return wire.snapshot()


def send_workspace(channel, files):
    seq = 0

    def emit(kind, **fields):
        nonlocal seq
        channel.send(dict(v=1, type=kind, seq=seq, **fields))
        seq += 1

    emit('begin', count=len(files), total=sum(map(len, files.values())))
    for path, data in sorted(files.items()):
        emit('file', path=path, size=len(data), sha256=wire.sha(data))
        for offset in range(0, len(data), 4096):
            emit('chunk', offset=offset, data=base64.b64encode(data[offset : offset + 4096]).decode())
        emit('end')
    emit('complete', sha256=wire.treehash(files))
