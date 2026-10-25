#!/usr/bin/python3
"""Bounded workspace data helpers reused by the business guest. No task code."""
import base64, hashlib, json, os, pathlib, socket, stat, struct, subprocess, time, unicodedata
ROOT = pathlib.Path('/work/project')
MAX_FILE=4*1024*1024
MAX_TOTAL=16*1024*1024

def sha(data): return hashlib.sha256(data).hexdigest()
def treehash(files):
    return sha(''.join(p+'\0'+str(len(files[p]))+'\0'+sha(files[p])+'\n' for p in sorted(files)).encode())
def pairs(items):
    result={}
    for k,v in items:
        if k in result: raise ValueError('duplicate')
        result[k]=v
    return result
def no_float(value): raise ValueError('numeric token')
def integer(value, maximum):
    if type(value) is not int or not 0<=value<=maximum: raise ValueError('integer')
    return value
def pathcheck(path):
    if type(path) is not str or len(path.encode())>1024: raise ValueError('path')
    parts=path.split('/')
    if not 1<=len(parts)<=16: raise ValueError('depth')
    for p in parts:
        q=p.lower()
        if not p or p in ('.','..') or len(p.encode())>255 or unicodedata.normalize('NFC',p)!=p or any(ord(x)<32 or ord(x)==127 or x in '\\:' for x in p): raise ValueError('component')
        if q in ('.git','.ssh','.aws','.azure','.gnupg','.config','.npmrc','.netrc','.pypirc','credentials','id_rsa','id_ed25519','.env') or q.startswith('.env.') or q.endswith(('.pem','.key','.p12')): raise ValueError('excluded')
    return parts

def snapshot():
    files={};names={};entries=0;total=0
    for directory,dirs,leaves in os.walk(ROOT,followlinks=False):
        for name in dirs+leaves:
            p=pathlib.Path(directory)/name;rel=str(p.relative_to(ROOT));pathcheck(rel)
            entries+=1
            if entries>1000: raise ValueError('count')
            folded=rel.casefold()
            if folded in names: raise ValueError('collision')
            names[folded]=rel
            st=p.lstat()
            if stat.S_ISDIR(st.st_mode): continue
            if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1 or st.st_size>MAX_FILE: raise ValueError('type')
            fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
            try:
                current=os.fstat(fd)
                if (current.st_dev,current.st_ino)!=(st.st_dev,st.st_ino): raise ValueError('mutation')
                with os.fdopen(fd,'rb',closefd=False) as f: data=f.read(MAX_FILE+1)
                if len(data)!=st.st_size or len(data)>MAX_FILE: raise ValueError('size')
            finally: os.close(fd)
            total+=len(data)
            if total>MAX_TOTAL: raise ValueError('total')
            files[rel]=data
    return files

