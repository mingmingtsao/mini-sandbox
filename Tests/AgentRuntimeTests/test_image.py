"""Runtime archive behavior: no host extraction or package execution."""
import io, os, pathlib, sys, tarfile, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Tools/GuestFixture'))
import build as legacy
sys.path.insert(0, str(ROOT/'Tools/AgentRuntime'))
try:
    import image
except ImportError:
    class image:
        # Prior diagnostic selector does not validate unselected archive members.
        safe_entries = staticmethod(lambda data: legacy.select_tar(data, {}))
        read_regular = staticmethod(legacy.read_regular)

def archive(name, kind=tarfile.REGTYPE, link='', payload=b'x'):
    b=io.BytesIO()
    with tarfile.open(fileobj=b,mode='w') as t:
        i=tarfile.TarInfo(name); i.type=kind; i.linkname=link
        i.size=len(payload) if kind==tarfile.REGTYPE else 0
        t.addfile(i,io.BytesIO(payload) if i.size else None)
    return b.getvalue()

class ImageTests(unittest.TestCase):
    def test_final_parent_inclusive_inventory(self):
        import stat, hashlib, inspect_runtime
        entries=image.finalized_entries({'a/b/c':(stat.S_IFREG|0o644,b'x',0,0)})
        expected=[dict(name=n,mode=oct(v[0]),bytes=len(v[1]),sha256=hashlib.sha256(v[1]).hexdigest()) for n,v in sorted(entries.items())]
        self.assertEqual(inspect_runtime.inventory(image.newc(entries)),expected)
        self.assertEqual(len(expected),3)

    def test_independent_cpio_invariants(self):
        import stat, inspect_runtime
        for name,value in [('TRAILER!!!',(stat.S_IFREG|0o644,b'x',0,0)),('./bad',(stat.S_IFREG|0o644,b'x',0,0)),('dir',(stat.S_IFDIR|0o755,b'payload',0,0)),('regular',(stat.S_IFREG|0o644,b'x',1,3))]:
            with self.subTest(name=name),self.assertRaises(ValueError):inspect_runtime.inventory(image.newc({name:value}))
        raw=image.newc({'file':(stat.S_IFREG|0o644,b'x',0,0)})
        with self.assertRaises(ValueError):inspect_runtime.inventory(raw[:120])
        with self.assertRaises(ValueError):inspect_runtime.inventory(raw+b'x')
    def test_reject_traversal_even_when_not_selected(self):
        with self.assertRaises(ValueError): image.safe_entries(archive('../outside'))
    def test_reject_special(self):
        for kind in (tarfile.FIFOTYPE,tarfile.CHRTYPE,tarfile.BLKTYPE):
            with self.subTest(kind=kind),self.assertRaises(ValueError): image.safe_entries(archive('dev/x',kind))
    def test_reject_link_escape(self):
        with self.assertRaises(ValueError): image.safe_entries(archive('lib/x',tarfile.SYMTYPE,'../../outside'))
    def test_regular_and_internal_link(self):
        self.assertIn('usr/bin/x',image.safe_entries(archive('usr/bin/x')))
        self.assertIn('lib/x',image.safe_entries(archive('lib/x',tarfile.SYMTYPE,'libx.so.1')))
    def test_guest_absolute_link_is_rebased_not_host_followed(self):
        value=image.safe_entries(archive('lib/x',tarfile.SYMTYPE,'/usr/lib/x'))['lib/x']
        self.assertEqual(value[1],b'../usr/lib/x')
    def test_bounds_duplicates_and_parent_alias(self):
        import gzip
        with self.assertRaises(ValueError): image.unpack_gzip(gzip.compress(b'x'*32),31)
        b=io.BytesIO()
        with tarfile.open(fileobj=b,mode='w') as t:
            for _ in range(2):
                i=tarfile.TarInfo('same');i.size=1;t.addfile(i,io.BytesIO(b'x'))
        with self.assertRaises(ValueError): image.safe_entries(b.getvalue())
        b=io.BytesIO()
        with tarfile.open(fileobj=b,mode='w') as t:
            i=tarfile.TarInfo('parent');i.type=tarfile.SYMTYPE;i.linkname='other';t.addfile(i)
            i=tarfile.TarInfo('parent/child');i.size=1;t.addfile(i,io.BytesIO(b'x'))
        with self.assertRaises(ValueError): image.safe_entries(b.getvalue())
    def test_nofollow_source_and_fifo(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as d:
            p=pathlib.Path(d); (p/'f').write_bytes(b'x'); (p/'s').symlink_to('f'); os.mkfifo(p/'fifo')
            for n in ('s','fifo'):
                with self.subTest(n=n),self.assertRaises(ValueError): image.read_regular(p/n,10)

if __name__=='__main__': unittest.main()
