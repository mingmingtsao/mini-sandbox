import importlib.util, pathlib, unittest, tempfile, os, hashlib
ROOT=pathlib.Path(__file__).resolve().parents[2]
class VendorDataTests(unittest.TestCase):
    def test_bounded_exact_artifact_and_rejections(self):
        path=ROOT/'Tools/AgentRuntime/vendor_data.py'
        self.assertTrue(path.exists(), 'bounded vendor artifact implementation missing')
        spec=importlib.util.spec_from_file_location('vendor_data',path)
        m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);root.chmod(0o700)
            src=root/'input';src.write_bytes(b'\x7fELFtest');src.chmod(0o400)
            sha=hashlib.sha256(src.read_bytes()).hexdigest()
            for name,size,digest in [('short',9,sha),('long',7,sha),('digest',8,'0'*64)]:
                with self.subTest(name=name),self.assertRaises((ValueError,OSError)):
                    m.copy_exact(src,root/name,size,digest)
            link=root/'link';link.symlink_to(src)
            with self.assertRaises((ValueError,OSError)):m.copy_exact(link,root/'symlink',8,sha)
            fifo=root/'fifo';os.mkfifo(fifo)
            with self.assertRaises((ValueError,OSError)):m.copy_exact(fifo,root/'fifo-out',8,sha)
            with self.assertRaises((ValueError,OSError)):m.copy_exact(src,root/'../escape',8,sha)
            raw=root/'padded';meta=m.copy_exact(src,raw,8,sha,pad_to_sector=True)
            self.assertEqual(raw.read_bytes(),src.read_bytes()+bytes(504));self.assertEqual(meta['diskBytes'],512)
            self.assertEqual(meta['diskSHA256'],hashlib.sha256(raw.read_bytes()).hexdigest())
            dst=root/'valid';m.copy_exact(src,dst,8,sha)
            self.assertEqual(dst.read_bytes(),src.read_bytes());self.assertEqual(dst.stat().st_mode&0o777,0o400)
            with self.assertRaises((ValueError,OSError)):m.copy_exact(src,dst,8,sha)
            src.chmod(0o600)
            with self.assertRaises((ValueError,OSError)):m.copy_exact(src,root/'mutable',8,sha)
