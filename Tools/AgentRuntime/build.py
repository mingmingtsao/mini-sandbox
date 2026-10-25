#!/usr/bin/env python3
"""Separate runtime image, fixed 256 MiB uncompressed budget. Offline build."""

import gzip
import hashlib
import json
import pathlib
import stat
import sys
import image
import inspect_bundle  # noqa: F401  # module handle patched by Tests/AgentRuntimeTests/test_base_snapshot.py
from RuntimeBundle import validated_base
from inspect_runtime import inventory


def main():
    root = pathlib.Path(sys.argv[1])
    base = pathlib.Path(sys.argv[2])
    out = pathlib.Path(sys.argv[3])
    flags = sys.argv[4:]
    allowed = {
        '--agent-probe',
        '--workspace',
        '--structural-metrics',
        '--claude-broker-restricted-v1',
        '--claude-broker-coding-v1',
        '--claude-business-runtime-v1',
    }
    if not set(flags).issubset(allowed) or len(flags) != len(set(flags)):
        raise ValueError('unknown or duplicate profile')
    if '--workspace' in flags and flags != ['--workspace']:
        raise ValueError('combined workspace profile')
    business = '--claude-business-runtime-v1' in flags
    if business and flags != ['--claude-business-runtime-v1']:
        raise ValueError('business profile is standalone')
    restricted = '--claude-broker-restricted-v1' in sys.argv[4:]
    coding = '--claude-broker-coding-v1' in sys.argv[4:]
    if restricted and coding:
        raise ValueError('profiles are mutually exclusive')
    if coding and not {'--agent-probe', '--structural-metrics'}.issubset(sys.argv[4:]):
        raise ValueError('coding profile requires agent probe and structural metrics')
    if restricted and not {'--agent-probe', '--structural-metrics'}.issubset(sys.argv[4:]):
        raise ValueError('restricted profile requires agent probe and structural metrics')
    if '--structural-metrics' in sys.argv[4:] and '--agent-probe' not in sys.argv[4:]:
        raise ValueError('structural metrics requires agent probe')
    image.legacy.reserve_output(out, pathlib.Path(__file__).resolve().parents[2])
    kernel, base_entries = validated_base(base)
    entries = {
        n: (
            v['mode'],
            v['data'],
            5 if n == 'dev/console' else 1 if n == 'dev/null' else 0,
            1 if n == 'dev/console' else 3 if n == 'dev/null' else 0,
        )
        for n, v in base_entries.items()
    }
    lock = json.loads(image.read_regular(pathlib.Path(__file__).parent / 'dependencies.lock.json', 1024 * 1024))
    if business:
        extra = json.loads(image.read_regular(pathlib.Path(__file__).parent / 'business-dependencies.lock.json', 65536))
        if (
            extra['schema'] != 1
            or extra['architecture'] != lock['architecture']
            or extra['indexSHA256'] != lock['indexSHA256']
        ):
            raise ValueError('business dependency index mismatch')
        names = {package['name'] for package in lock['packages']}
        for package in extra['packages']:
            if package['name'] in names:
                raise ValueError('duplicate business dependency')
            names.add(package['name'])
            lock['packages'].append(package)
    kernel_entries = None
    for package in lock['packages']:
        data = image.legacy.read_source(root / 'downloads' / package['file'], package['sha256'], 64 * 1024 * 1024)
        parsed = image.safe_entries(data)
        if package['name'] == 'linux-virt':
            kernel_entries = parsed
            continue
        for n, v in parsed.items():
            if n.startswith('.'):
                continue  # APK metadata/install scripts are data only, never run or included
            if n in entries and stat.S_ISDIR(v[0]) and stat.S_ISDIR(entries[n][0]):
                continue
            entries[n] = v
    prefix = 'lib/modules/' + image.legacy.KERNEL_RELEASE + '/'
    dep = kernel_entries[prefix + 'modules.dep'][1].decode()
    order = image.legacy.module_order(dep, ['kernel/drivers/block/virtio_blk.ko.gz', 'kernel/fs/ext4/ext4.ko.gz'])
    loads = []
    for n in order:
        raw = image.unpack_gzip(kernel_entries[prefix + n][1], 8 * 1024 * 1024)
        image.legacy.validate_elf(raw)
        if ('vermagic=' + image.legacy.VERMAGIC).encode() + b'\0' not in raw:
            raise ValueError('kernel module ABI')
        path = prefix + n[:-3]
        entries[path] = (stat.S_IFREG | 0o644, raw, 0, 0)
        loads.append('/bin/busybox insmod /' + path + ' || hold')
    for n in sorted(entries):
        if n.endswith('.ko') and 'vmw_vsock' in n:
            loads.append('/bin/busybox insmod /' + n + ' || hold')
    # Dependency order for already-verified vsock modules is explicit.
    loads = [x for x in loads if 'vmw_vsock' not in x] + [
        '/bin/busybox insmod /' + prefix + 'kernel/net/vmw_vsock/' + n + '.ko || hold'
        for n in ('vsock', 'vmw_vsock_virtio_transport_common', 'vmw_vsock_virtio_transport')
    ]
    here = pathlib.Path(__file__).parent
    for n in () if business else ('guest.py', 'protocol.py'):
        entries['runtime/' + n] = (stat.S_IFREG | 0o644, image.read_regular(here / n, 65536), 0, 0)
    for n in () if business else ('logic.py', 'test_logic.py', 'task.py'):
        entries['fixture/' + n] = (stat.S_IFREG | 0o644, image.read_regular(here / 'fixture' / n, 65536), 0, 0)
    for n in ('tmp', 'work'):
        entries[n] = (stat.S_IFDIR | 0o755, b'', 0, 0)
    init = (
        '''#!/bin/sh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
hold() { echo RUNTIME_INIT_FAILED; while :; do /bin/busybox sleep 1; done; }
/bin/busybox mount -t proc proc /proc || hold
/bin/busybox mount -t sysfs sysfs /sys || hold
/bin/busybox mount -t devtmpfs devtmpfs /dev || hold
'''
        + '\n'.join(loads)
        + '''
/sbin/mkfs.ext4 -q -F /dev/vda || hold
/bin/busybox mount -t ext4 -o nosuid,nodev /dev/vda /work || hold
/bin/busybox mkdir -p /work/project /work/tmp
/bin/busybox cp /fixture/* /work/project/ || hold
/usr/bin/python3 -B /runtime/guest.py
hold
'''
    )
    if '--agent-probe' in flags or business:
        if not business:
            entries['runtime/supervisor_check.py'] = (
                stat.S_IFREG | 0o644,
                image.read_regular(here / 'fixture/supervisor_check.py', 65536),
                0,
                0,
            )
        for n in ('agent_supervisor.py',):
            entries['runtime/' + n] = (stat.S_IFREG | 0o644, image.read_regular(here / n, 65536), 0, 0)
        for n in () if business else ('capture.py', 'guest-launch.json'):
            entries['runtime/' + n] = (
                stat.S_IFREG | 0o644,
                image.read_regular(here.parent / 'AgentProtocolProbe' / n, 65536),
                0,
                0,
            )
        if restricted:
            entries['runtime/guest-launch.json'] = (
                stat.S_IFREG | 0o644,
                image.read_regular(here.parent / 'AgentProtocolProbe' / 'claude-broker-restricted-v1.json', 65536),
                0,
                0,
            )
        if coding:
            entries['runtime/guest-launch.json'] = (
                stat.S_IFREG | 0o644,
                image.read_regular(here.parent / 'AgentProtocolProbe' / 'claude-broker-coding-v1.json', 65536),
                0,
                0,
            )
        if business:
            entries['runtime/business-launch.json'] = (
                stat.S_IFREG | 0o644,
                image.read_regular(here.parent / 'AgentProtocolProbe' / 'claude-business-runtime-v1.json', 65536),
                0,
                0,
            )
            for n in ('business_cli.py', 'business_workspace.py', 'workspace_data.py'):
                entries['runtime/' + n] = (stat.S_IFREG | 0o644, image.read_regular(here / n, 65536), 0, 0)
        loader = 'lib/ld-musl-aarch64.so.1'
        assert stat.S_ISREG(entries[loader][0])
        closure = {'/' + loader: hashlib.sha256(entries[loader][1]).hexdigest()}
        assert entries['lib/libc.musl-aarch64.so.1'][1] == b'ld-musl-aarch64.so.1'
        closure['/lib/libc.musl-aarch64.so.1'] = closure['/' + loader]
        entries['runtime/loader.json'] = (stat.S_IFREG | 0o644, json.dumps(closure).encode(), 0, 0)
        entries['runtime/profile.json'] = (stat.S_IFREG | 0o644, b'{"profile":"pinned-cli-local-capture-v1"}', 0, 0)
        if restricted:
            entries['runtime/profile.json'] = (stat.S_IFREG | 0o644, b'{"profile":"claude-broker-restricted-v1"}', 0, 0)
        if coding:
            entries['runtime/profile.json'] = (stat.S_IFREG | 0o644, b'{"profile":"claude-broker-coding-v1"}', 0, 0)
        if business:
            entries['runtime/profile.json'] = (stat.S_IFREG | 0o644, b'{"profile":"claude-business-runtime-v1"}', 0, 0)
        if '--structural-metrics' in sys.argv[4:]:
            entries['runtime/structural-metrics-v1'] = (stat.S_IFREG | 0o444, b'1', 0, 0)
        init = init.replace(
            '/usr/bin/python3 -B /runtime/guest.py',
            '''/bin/busybox mkdir -p /opt/agent-probe /run/agent-probe
/bin/busybox mount -t tmpfs -o size=285499392,nosuid,nodev tmpfs /opt/agent-probe || hold
/bin/busybox mount -t tmpfs -o size=16777216,nosuid,nodev tmpfs /run/agent-probe || hold
/bin/busybox ip link set lo up || hold
/usr/bin/python3 -B /runtime/agent_supervisor.py --materialize || hold
/usr/bin/python3 -B /runtime/guest.py''',
        )
    if business:
        init = init.replace('/bin/busybox cp /fixture/* /work/project/ || hold', '')
        init = init.replace('/usr/bin/python3 -B /runtime/guest.py', '/usr/bin/python3 -B /runtime/business_cli.py')
    if '--workspace' in flags:
        entries['runtime/workspace_guest.py'] = (
            stat.S_IFREG | 0o644,
            image.read_regular(here / 'workspace_guest.py', 65536),
            0,
            0,
        )
        init = init.replace('/bin/busybox cp /fixture/* /work/project/ || hold', '')
        init = init.replace('/usr/bin/python3 -B /runtime/guest.py', '/usr/bin/python3 -B /runtime/workspace_guest.py')
    entries['init'] = (stat.S_IFREG | 0o755, init.encode(), 0, 0)
    for n in ('usr/bin/node', 'usr/bin/python3.14', 'usr/bin/git'):
        image.legacy.validate_elf(entries[n][1])
    entries = image.finalized_entries(entries)
    raw = image.newc(entries)
    actual = inventory(raw)
    expected = [
        {'name': n, 'mode': oct(v[0]), 'bytes': len(v[1]), 'sha256': hashlib.sha256(v[1]).hexdigest()}
        for n, v in sorted(entries.items())
    ]
    if actual != expected:
        raise ValueError('final inventory mismatch')
    compressed = gzip.compress(raw, compresslevel=6, mtime=0)
    if len(compressed) > 128 * 1024 * 1024:
        raise ValueError('compressed budget')
    image.legacy.exclusive_write(out / 'Image', kernel)
    image.legacy.exclusive_write(out / 'runtime.cpio.gz', compressed)
    manifest = {
        'schema': 1,
        'kind': 'agent-runtime-increment-not-full-agent',
        'kernelSHA256': hashlib.sha256(kernel).hexdigest(),
        'initramfsSHA256': hashlib.sha256(compressed).hexdigest(),
        'uncompressedBytes': len(raw),
        'compressedBytes': len(compressed),
        'limits': {
            'uncompressed': image.MAX_RAW,
            'file': image.MAX_FILE,
            'entries': image.MAX_ENTRIES,
            'disk': 67108864,
            'RAM': 1073741824,
            'CPUs': 2,
            'frame': 16384,
            'output': 262144,
        },
        'dependencies': lock,
        'entries': actual,
    }
    if business:
        manifest['kind'] = 'business-runtime-v1'
        manifest['limits']['output'] = 131072
        manifest['businessProfile'] = {
            'name': 'claude-business-runtime-v1',
            'vendorSHA256': '028ad6b4c0ed304a116eb1efa6f1d752630f6691aa70004a79406026a023b332',
            'vendorDiskSHA256': 'c4e512ea944c420c80285b4c4bd817098d9845ac6aa6e423bbbb58b8d3a9bf43',
            'vendorReadOnly': True,
            'launchSHA256': hashlib.sha256(entries['runtime/business-launch.json'][1]).hexdigest(),
            'guestSeconds': 855,
            'hostSeconds': 900,
            'stopSeconds': 15,
            'loaderClosure': closure,
        }
        identity = {
            'schema': 1,
            'profile': 'claude-business-runtime-v1',
            'kernelSHA256': manifest['kernelSHA256'],
            'initramfsSHA256': manifest['initramfsSHA256'],
            'launchSHA256': manifest['businessProfile']['launchSHA256'],
            'vendorSHA256': manifest['businessProfile']['vendorSHA256'],
            'vendorDiskSHA256': manifest['businessProfile']['vendorDiskSHA256'],
            'vendorReadOnly': True,
        }
        image.legacy.exclusive_write(out / 'business.json', (json.dumps(identity, indent=2) + '\n').encode())
    if '--agent-probe' in sys.argv[4:]:
        manifest['agentProbeProfile'] = {
            'name': 'pinned-cli-local-capture-v1',
            'vendorBytes': 285493120,
            'vendorSHA256': '028ad6b4c0ed304a116eb1efa6f1d752630f6691aa70004a79406026a023b332',
            'vendorDiskBytes': 285493248,
            'vendorDiskSHA256': 'c4e512ea944c420c80285b4c4bd817098d9845ac6aa6e423bbbb58b8d3a9bf43',
            'vendorReadOnly': True,
            'materializationTmpfsBytes': 285499392,
            'homeTmpfsBytes': 16777216,
            'commandSeconds': 55,
            'guestSeconds': 75,
            'hostSeconds': 95,
            'stopSeconds': 10,
            'outerSeconds': 112,
            'CPUSeconds': 20,
            'FSIZE': 67108864,
            'NOFILE': 64,
            'loaderClosure': closure,
            'captureSHA256': hashlib.sha256(entries['runtime/capture.py'][1]).hexdigest(),
        }
    if '--workspace' in flags:
        manifest['workspaceProfile'] = 'workspace-fixture-v1'
    if '--structural-metrics' in sys.argv[4:]:
        manifest['agentProbeProfile']['structuralMetricsV1'] = True
    if restricted:
        # The native harness profile/budgets stay fixed; client config is distinct.
        manifest['agentProbeProfile']['clientProfile'] = 'claude-broker-restricted-v1'
        manifest['agentProbeProfile']['launchSHA256'] = hashlib.sha256(
            entries['runtime/guest-launch.json'][1]
        ).hexdigest()
    if coding:
        manifest['agentProbeProfile']['clientProfile'] = 'claude-broker-coding-v1'
        manifest['agentProbeProfile']['launchSHA256'] = hashlib.sha256(
            entries['runtime/guest-launch.json'][1]
        ).hexdigest()
    image.legacy.exclusive_write(out / 'runtime.json', (json.dumps(manifest, indent=2) + '\n').encode())
    print(json.dumps({k: v for k, v in manifest.items() if k not in ('dependencies', 'entries')}))


if __name__ == '__main__':
    main()
