#!/usr/bin/env python3
"""Separate runtime image, fixed 256 MiB uncompressed budget. Offline build."""
import gzip,hashlib,json,pathlib,stat,sys
import image
import inspect_bundle
from RuntimeBundle import validated_base
from inspect_runtime import inventory

def main():
    root=pathlib.Path(sys.argv[1]);base=pathlib.Path(sys.argv[2]);out=pathlib.Path(sys.argv[3])
    image.legacy.reserve_output(out,pathlib.Path(__file__).resolve().parents[2])
    kernel,base_entries=validated_base(base)
    entries={n:(v['mode'],v['data'],5 if n=='dev/console' else 1 if n=='dev/null' else 0,1 if n=='dev/console' else 3 if n=='dev/null' else 0) for n,v in base_entries.items()}
    lock=json.loads(image.read_regular(pathlib.Path(__file__).parent/'dependencies.lock.json',1024*1024))
    kernel_entries=None
    for package in lock['packages']:
        data=image.legacy.read_source(root/'downloads'/package['file'],package['sha256'],64*1024*1024)
        parsed=image.safe_entries(data)
        if package['name']=='linux-virt':kernel_entries=parsed;continue
        for n,v in parsed.items():
            if n.startswith('.'):continue # APK metadata/install scripts are data only, never run or included
            if n in entries and stat.S_ISDIR(v[0]) and stat.S_ISDIR(entries[n][0]):continue
            entries[n]=v
    prefix='lib/modules/'+image.legacy.KERNEL_RELEASE+'/'
    dep=kernel_entries[prefix+'modules.dep'][1].decode()
    order=image.legacy.module_order(dep,['kernel/drivers/block/virtio_blk.ko.gz','kernel/fs/ext4/ext4.ko.gz'])
    loads=[]
    for n in order:
        raw=image.unpack_gzip(kernel_entries[prefix+n][1],8*1024*1024)
        image.legacy.validate_elf(raw)
        if ('vermagic='+image.legacy.VERMAGIC).encode()+b'\0' not in raw:raise ValueError('kernel module ABI')
        path=prefix+n[:-3];entries[path]=(stat.S_IFREG|0o644,raw,0,0);loads.append('/bin/busybox insmod /'+path+' || hold')
    for n in sorted(entries):
        if n.endswith('.ko') and 'vmw_vsock' in n:loads.append('/bin/busybox insmod /'+n+' || hold')
    # Dependency order for already-verified vsock modules is explicit.
    loads=[x for x in loads if 'vmw_vsock' not in x]+['/bin/busybox insmod /'+prefix+'kernel/net/vmw_vsock/'+n+'.ko || hold' for n in ('vsock','vmw_vsock_virtio_transport_common','vmw_vsock_virtio_transport')]
    here=pathlib.Path(__file__).parent
    for n in ('guest.py','protocol.py'):
        entries['runtime/'+n]=(stat.S_IFREG|0o644,image.read_regular(here/n,65536),0,0)
    for n in ('logic.py','test_logic.py','task.py'):
        entries['fixture/'+n]=(stat.S_IFREG|0o644,image.read_regular(here/'fixture'/n,65536),0,0)
    for n in ('tmp','work'):entries[n]=(stat.S_IFDIR|0o755,b'',0,0)
    init='''#!/bin/sh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
hold() { echo RUNTIME_INIT_FAILED; while :; do /bin/busybox sleep 1; done; }
/bin/busybox mount -t proc proc /proc || hold
/bin/busybox mount -t sysfs sysfs /sys || hold
/bin/busybox mount -t devtmpfs devtmpfs /dev || hold
'''+ '\n'.join(loads)+'''
/sbin/mkfs.ext4 -q -F /dev/vda || hold
/bin/busybox mount -t ext4 -o nosuid,nodev /dev/vda /work || hold
/bin/busybox mkdir -p /work/project /work/tmp
/bin/busybox cp /fixture/* /work/project/ || hold
/usr/bin/python3 -B /runtime/guest.py
hold
'''
    entries['init']=(stat.S_IFREG|0o755,init.encode(),0,0)
    for n in ('usr/bin/node','usr/bin/python3.14','usr/bin/git'):image.legacy.validate_elf(entries[n][1])
    entries=image.finalized_entries(entries)
    raw=image.newc(entries)
    actual=inventory(raw)
    expected=[{'name':n,'mode':oct(v[0]),'bytes':len(v[1]),'sha256':hashlib.sha256(v[1]).hexdigest()} for n,v in sorted(entries.items())]
    if actual!=expected:raise ValueError('final inventory mismatch')
    compressed=gzip.compress(raw,compresslevel=6,mtime=0)
    if len(compressed)>128*1024*1024:raise ValueError('compressed budget')
    image.legacy.exclusive_write(out/'Image',kernel);image.legacy.exclusive_write(out/'runtime.cpio.gz',compressed)
    manifest={'schema':1,'kind':'agent-runtime-increment-not-full-agent','kernelSHA256':hashlib.sha256(kernel).hexdigest(),'initramfsSHA256':hashlib.sha256(compressed).hexdigest(),'uncompressedBytes':len(raw),'compressedBytes':len(compressed),'limits':{'uncompressed':image.MAX_RAW,'file':image.MAX_FILE,'entries':image.MAX_ENTRIES,'disk':67108864,'RAM':1073741824,'CPUs':2,'frame':16384,'output':262144},'dependencies':lock,'entries':actual}
    image.legacy.exclusive_write(out/'runtime.json',(json.dumps(manifest,indent=2)+'\n').encode())
    print(json.dumps({k:v for k,v in manifest.items() if k not in ('dependencies','entries')}))
if __name__=='__main__':main()
