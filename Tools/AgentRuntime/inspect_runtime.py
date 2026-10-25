#!/usr/bin/env python3
"""Independent bounded newc inventory check; does not call the image writer."""
import hashlib, json, pathlib, stat, sys
import image

def inventory(raw):
    if len(raw)>image.MAX_RAW: raise ValueError('raw budget')
    result=[]; names=set(); offset=0
    while offset+110<=len(raw):
        h=raw[offset:offset+110]; offset+=110
        if h[:6]!=b'070701' or any(x not in b'0123456789abcdef' for x in h[6:]): raise ValueError('header')
        f=[int(h[6+8*i:14+8*i],16) for i in range(13)]
        mode,size,n=f[1],f[6],f[11]
        if not 1<=n<=4096 or offset+n>len(raw) or size>image.MAX_FILE: raise ValueError('bounds')
        name=raw[offset:offset+n];offset+=n
        if name[-1:]!=b'\0' or b'\0' in name[:-1]:raise ValueError('name')
        name=name[:-1].decode('utf8')
        pad=-offset%4
        if any(raw[offset:offset+pad]):raise ValueError('padding')
        offset+=pad
        if offset+size>len(raw):raise ValueError('payload')
        data=raw[offset:offset+size];offset+=size
        pad=-offset%4
        if any(raw[offset:offset+pad]):raise ValueError('padding')
        offset+=pad
        if name=='TRAILER!!!':
            if mode or size or any(f[i] for i in (2,3,5,7,8,9,10,12)) or any(raw[offset:]):raise ValueError('trailer')
            for item in result:
                for parent in pathlib.PurePosixPath(item['name']).parents:
                    if str(parent)=='.':continue
                    if not any(x['name']==str(parent) and stat.S_ISDIR(int(x['mode'],8)) for x in result):raise ValueError('missing directory')
            return result
        if not name or name.startswith('/') or '\\' in name or any(p in ('','.','..') for p in name.split('/')) or name in names:raise ValueError('path')
        if any(f[i] for i in (2,3,5,7,8,12)) or f[4]!=(2 if stat.S_ISDIR(mode) else 1):raise ValueError('metadata')
        kind=stat.S_IFMT(mode)
        if kind not in (stat.S_IFDIR,stat.S_IFREG,stat.S_IFLNK,stat.S_IFCHR):raise ValueError('type')
        devices={'dev/console':(5,1),'dev/null':(1,3)}
        if kind==stat.S_IFCHR or name in devices:
            if kind!=stat.S_IFCHR or devices.get(name)!=(f[9],f[10]) or data:raise ValueError('device')
        elif f[9] or f[10]:raise ValueError('nondevice numbers')
        if kind==stat.S_IFDIR and data:raise ValueError('directory payload')
        if kind==stat.S_IFLNK:image.target(name,data.decode('ascii'))
        names.add(name)
        if len(names)>image.MAX_ENTRIES:raise ValueError('entry budget')
        result.append(dict(name=name,mode=oct(mode),bytes=size,sha256=hashlib.sha256(data).hexdigest()))
    raise ValueError('missing trailer')

def inspect(path):
    path=pathlib.Path(path)
    manifest=json.loads(image.read_regular(path/'runtime.json',4*1024*1024))
    compressed=image.read_regular(path/'runtime.cpio.gz',128*1024*1024)
    raw=image.unpack_gzip(compressed)
    entries=inventory(raw)
    assert len(raw)==manifest['uncompressedBytes'] and len(compressed)==manifest['compressedBytes']
    assert hashlib.sha256(compressed).hexdigest()==manifest['initramfsSHA256']
    assert entries==manifest['entries'],f"inventory mismatch: actual={len(entries)} listed={len(manifest['entries'])}"
    return {'entries':len(entries),'raw':len(raw),'compressed':len(compressed),'sha256':manifest['initramfsSHA256']}
if __name__=='__main__': print(json.dumps(inspect(sys.argv[1])))
