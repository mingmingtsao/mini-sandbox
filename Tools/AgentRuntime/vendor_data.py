"""Exact fixed vendor blob; never an archive and never executed on host."""
import hashlib, json, os, pathlib, stat, sys
SIZE=285493120
SHA256='028ad6b4c0ed304a116eb1efa6f1d752630f6691aa70004a79406026a023b332'

def safe_path(path):
    path=pathlib.Path(path)
    if not path.is_absolute() or '..' in path.parts or '.' in str(path).split('/'):
        raise ValueError('absolute canonical path required')
    for p in [path.parent]+list(path.parent.parents):
        s=p.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid not in (0,os.getuid()) or s.st_mode&0o022:
            raise ValueError('unsafe ancestry')
    if path.parent.stat().st_mode&0o077:raise ValueError('private leaf required')
    return path

def copy_exact(source, output, size=SIZE, digest=SHA256, pad_to_sector=False):
    source=safe_path(source);output=safe_path(output)
    if type(size) is not int or not 0<size<=SIZE or len(digest)!=64 or any(c not in '0123456789abcdef' for c in digest):raise ValueError('fixed bounds')
    fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        s=os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_size!=size or s.st_nlink!=1 or s.st_uid!=os.getuid() or s.st_mode&0o222:raise ValueError('immutable exact regular input')
        out=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        try:
            h=hashlib.sha256();remaining=size
            while remaining:
                chunk=os.read(fd,min(1048576,remaining))
                if not chunk:raise ValueError('short input')
                h.update(chunk);remaining-=len(chunk)
                view=memoryview(chunk)
                while view:
                    n=os.write(out,view)
                    if n<=0:raise OSError('short write')
                    view=view[n:]
            if os.read(fd,1) or h.hexdigest()!=digest:raise ValueError('size/digest mismatch')
            padding=bytes((-size)%512) if pad_to_sector else b''
            if padding:
                if os.write(out,padding)!=len(padding):raise OSError('padding write')
                h.update(padding)
            os.fsync(out);os.fchmod(out,0o400)
        finally:os.close(out)
    finally:os.close(fd)
    return {'schema':1,'bytes':size,'sha256':digest,'diskBytes':size+len(padding),'diskSHA256':h.hexdigest(),'readOnly':True,'format':'exact-raw-blob-zero-sector-padding'}

if __name__=='__main__':
    result=copy_exact(sys.argv[1],sys.argv[2],pad_to_sector=True);print(json.dumps(result))
