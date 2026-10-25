"""Synthetic VM-only task, not an Agent and never executed on the host."""
import hashlib,json,pathlib,subprocess,sys
p=pathlib.Path('logic.py');before=p.read_bytes()
red=subprocess.run([sys.executable,'test_logic.py'],capture_output=True)
assert red.returncode==1
assert before==b'def add(a, b):\n    return a - b\n'
p.write_bytes(b'def add(a, b):\n    return a + b\n')
green=subprocess.run([sys.executable,'test_logic.py'],capture_output=True)
assert green.returncode==0
pathlib.Path('/work/session-marker').write_text('private-session-write')
print(json.dumps({'read':before.decode(),'beforeSHA256':hashlib.sha256(before).hexdigest(),'afterSHA256':hashlib.sha256(p.read_bytes()).hexdigest(),'redExit':red.returncode,'testExit':green.returncode,'testStdout':green.stdout.decode(),'command':[sys.executable,'test_logic.py']}),flush=True)
