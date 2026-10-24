"""Runtime v1: big-endian length + strict bounded JSON. No peer-selected routing."""
import json,struct
MAX_FRAME=16384
TYPES={'hello','launch','stdout','stderr','exit','cancel','stop'}
def validate(x):
    if not isinstance(x,dict) or type(x.get('v')) is not int or x.get('v')!=1 or x.get('type') not in TYPES or type(x.get('id')) is not int or not 0<=x['id']<=64:raise ValueError('frame schema')
    return x
def unique_pairs(pairs):
    out={}
    for k,v in pairs:
        if k in out:raise ValueError('duplicate JSON key')
        out[k]=v
    return out
def encode(x):
    b=json.dumps(validate(x),separators=(',',':')).encode()
    if not 0<len(b)<=MAX_FRAME:raise ValueError('frame bound')
    return struct.pack('>I',len(b))+b
class Parser:
    def __init__(self):self.data=bytearray();self.dead=False;self.count=0
    def feed(self,b):
        if self.dead:raise ValueError('poisoned')
        try:
            if len(self.data)+len(b)>MAX_FRAME+4:raise ValueError('buffer bound')
            self.data.extend(b);out=[]
            while len(self.data)>=4:
                size=struct.unpack('>I',self.data[:4])[0]
                if not 0<size<=MAX_FRAME:raise ValueError('frame bound')
                if len(self.data)<4+size:break
                x=validate(json.loads(self.data[4:4+size],object_pairs_hook=unique_pairs));del self.data[:4+size]
                self.count+=1
                if self.count>512:raise ValueError('frame count')
                out.append(x)
            return out
        except Exception:
            self.dead=True;self.data.clear();raise ValueError('invalid frame')
