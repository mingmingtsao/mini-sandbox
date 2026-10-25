import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILDER = ROOT / 'Tools/GuestFixture/build.py'

class BuilderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('fixture_builder', BUILDER)
        assert spec is not None and spec.loader is not None
        cls.b = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.b)

    def test_selected_tar_hash_paths_and_bounds(self):
        import io, tarfile, hashlib
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w') as tf:
            entry = tarfile.TarInfo('./bin/busybox')
            entry.size = 3
            tf.addfile(entry, io.BytesIO(b'abc'))
        raw = stream.getvalue()
        self.assertTrue(hasattr(self.b, 'select_tar'), 'safe selective tar reader missing')
        self.assertEqual(self.b.select_tar(raw, {'bin/busybox': 3}), {'bin/busybox': b'abc'})
        with self.assertRaises(ValueError): self.b.select_tar(raw, {'bin/busybox': 2})
        with self.assertRaises(ValueError): self.b.select_tar(b'corrupt', {'bin/busybox': 3})
        for name in ('../oops', '/absolute', 'a/../b', 'a//b', 'a\\b', ''):
            with self.subTest(name=name), self.assertRaises(ValueError): self.b.safe_name(name)
        self.assertEqual(self.b.checked_hash(b'abc', hashlib.sha256(b'abc').hexdigest()), b'abc')
        with self.assertRaises(ValueError): self.b.checked_hash(b'abc', '0' * 64)

    def test_tar_rejects_selected_links_and_duplicate_names(self):
        import io, tarfile
        self.assertTrue(hasattr(self.b, 'select_tar'), 'safe selective tar reader missing')
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE):
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode='w') as tf:
                entry = tarfile.TarInfo('bin/busybox'); entry.type = kind; entry.linkname = '/etc/passwd'
                tf.addfile(entry)
            with self.assertRaises(ValueError): self.b.select_tar(stream.getvalue(), {'bin/busybox': 100})
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w') as tf:
            for _ in range(2): tf.addfile(tarfile.TarInfo('bin/busybox'))
        with self.assertRaises(ValueError): self.b.select_tar(stream.getvalue(), {'bin/busybox': 100})

    def test_zboot_checks_and_output_preservation(self):
        import gzip, struct, hashlib, tempfile, os
        self.assertTrue(hasattr(self.b, 'decode_zboot'), 'bounded zboot decoder missing')
        raw = bytearray(64); raw[56:60] = b'ARM\x64'; struct.pack_into('<Q', raw, 16, 64)
        compressed = gzip.compress(bytes(raw), mtime=0)
        image = bytearray(32); image[:2] = b'MZ'; image[4:8] = b'zimg'
        struct.pack_into('<II', image, 8, 32, len(compressed)); image[24:28] = b'gzip'
        image += compressed
        digest = hashlib.sha256(raw).hexdigest()
        self.assertEqual(self.b.decode_zboot(bytes(image), digest, 64), raw)
        for offset, value in ((0, 0), (4, 0), (24, 0), (8, 255), (12, 255)):
            bad = bytearray(image); bad[offset] = value
            with self.assertRaises(ValueError): self.b.decode_zboot(bytes(bad), digest, 64)
        with self.assertRaises(ValueError): self.b.decode_zboot(bytes(image), digest, 63)
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as td:
            parent=pathlib.Path(td)
            out=parent/'existing'; out.mkdir(); (out/'sentinel').write_bytes(b'keep')
            with self.assertRaises(ValueError): self.b.reserve_output(out, ROOT)
            self.assertEqual((out/'sentinel').read_bytes(), b'keep')
            (parent/'link').symlink_to(out, target_is_directory=True)
            with self.assertRaises(ValueError): self.b.reserve_output(parent/'link'/'child', ROOT)
            with self.assertRaises(ValueError): self.b.reserve_output(ROOT/'unsafe-artifact', ROOT)
            fresh=self.b.reserve_output(parent/'new', ROOT)
            self.assertEqual(fresh, parent/'new'); self.assertTrue(fresh.is_dir())

    def test_cpio_deterministic_modules_and_elf(self):
        import stat, struct
        self.assertTrue(hasattr(self.b, 'newc'), 'deterministic newc writer missing')
        entries={'init':(stat.S_IFREG|0o755,b'hello',0,0), 'dev/console':(stat.S_IFCHR|0o600,b'',5,1)}
        blob=self.b.newc(entries)
        self.assertEqual(blob,self.b.newc(dict(reversed(list(entries.items())))))
        self.assertTrue(blob.startswith(b'070701')); self.assertIn(b'TRAILER!!!\0',blob)
        with self.assertRaises(ValueError): self.b.newc({'../evil':(stat.S_IFREG,b'',0,0)})
        with self.assertRaises(ValueError): self.b.newc({'evil':(stat.S_IFCHR,b'',1,1)})
        deps='a.ko: b.ko\nb.ko:\n'
        self.assertEqual(self.b.module_order(deps,['a.ko']), ['b.ko','a.ko'])
        for bad in ('a.ko: missing.ko\n','a.ko: a.ko\n','../a.ko:\n'):
            with self.assertRaises(ValueError): self.b.module_order(bad,['a.ko'])
        with self.assertRaises(ValueError): self.b.validate_elf(b'bad', static=True)
        elf=bytearray(64);elf[:6]=b'\x7fELF\x02\x01';struct.pack_into('<H',elf,18,183)
        self.b.validate_elf(elf,static=True)
        struct.pack_into('<Q',elf,32,1024);struct.pack_into('<H',elf,56,1)
        with self.assertRaises(ValueError): self.b.validate_elf(elf,static=True)

    def test_squash_selected_regular_and_manifest_schema(self):
        self.assertTrue(hasattr(self.b, 'selected_squash_entry'), 'selective squashfs reader missing')
        class Entry:
            path='/modules/a.ko'; mode=0o100644; size=3
            def read_bytes(self): return b'abc'
        self.assertEqual(self.b.selected_squash_entry(Entry(),3), b'abc')
        with self.assertRaises(ValueError): self.b.selected_squash_entry(Entry(),2)
        bad=Entry();bad.mode=0o120777
        with self.assertRaises(ValueError): self.b.selected_squash_entry(bad,10)
        bad=Entry();bad.path='/modules/../escape'
        with self.assertRaises(ValueError): self.b.selected_squash_entry(bad,10)
        with self.assertRaises(ValueError): self.b.load_modules(b'corrupt')
        m=self.b.manifest(b'kernel',b'cpio',b'probe')
        self.assertEqual(set(m), {'schemaVersion','kernelFile','kernelSHA256','initramfsFile','initramfsSHA256','probeSHA256','protocolVersion','workloadSHA256','kernelRelease'})
        import hashlib,json
        identity={k:m[k] for k in ('schemaVersion','kernelSHA256','initramfsSHA256','protocolVersion')}
        self.assertEqual(m['workloadSHA256'],hashlib.sha256(json.dumps(identity,sort_keys=True,separators=(',',':')).encode()).hexdigest())

    def test_inspector_and_cli_preserve_output(self):
        import os,tempfile,subprocess,sys
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as td:
            out=pathlib.Path(td)/'existing';out.mkdir();(out/'sentinel').write_bytes(b'keep')
            result=subprocess.run([sys.executable,str(BUILDER),'--source-dir',td,'--wheel','missing','--scratch',td,'--output',str(out)],capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual((out/'sentinel').read_bytes(),b'keep')
            self.assertFalse((out/'bundle.json').exists())
        inspector=ROOT/'Tools/GuestFixture/inspect_bundle.py'
        self.assertTrue(inspector.is_file(), 'offline archive inspector missing')
        sys.path.insert(0,str(BUILDER.parent))
        spec=importlib.util.spec_from_file_location('fixture_inspector',inspector)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        entries=module.parse_newc(self.b.newc({'init':(0o100755,b'hello',0,0)}))
        self.assertEqual(entries['init']['data'], b'hello')
        for bad in (b'bad', self.b.newc({'init':(0o100755,b'hello',0,0)})[:120]):
            with self.assertRaises(ValueError):module.parse_newc(bad)

class MalformedInputTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        BuilderTest.setUpClass.__func__(cls)

    def assert_fifo_rejected(self, manifest=False):
        import os, subprocess, sys, tempfile
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as td:
            path = pathlib.Path(td) / ('bundle.json' if manifest else 'source')
            os.mkfifo(path)
            expression = 'inspect_bundle.inspect(sys.argv[1])' if manifest else "build.read_source(sys.argv[1], '0' * 64, 8192)"
            code = ('import sys, build, inspect_bundle\ntry:\n    ' + expression +
                    '\nexcept ValueError as exc:\n    print(exc)\nelse:\n    raise SystemExit(2)\n')
            try:
                result = subprocess.run([sys.executable, '-c', code, td if manifest else str(path)],
                                        cwd=BUILDER.parent, capture_output=True, text=True, timeout=1)
            except subprocess.TimeoutExpired:
                self.fail('writerless FIFO blocked instead of rejecting nonregular input')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('type or size', result.stdout)

    def test_source_fifo_rejected_without_blocking(self):
        self.assert_fifo_rejected()

    def test_manifest_fifo_rejected_without_blocking(self):
        self.assert_fifo_rejected(manifest=True)
if __name__ == '__main__':
    unittest.main()
