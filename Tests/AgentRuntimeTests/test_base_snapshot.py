import importlib.util, pathlib, sys, unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tools/AgentRuntime'))
import image
spec=importlib.util.spec_from_file_location('runtime_build',ROOT/'Tools/AgentRuntime/build.py')
build=importlib.util.module_from_spec(spec);spec.loader.exec_module(build)

class SnapshotTests(unittest.TestCase):
    def test_no_unbounded_decompression_after_validation(self):
        # Stop at the first package input: old code reaches forbidden gzip.decompress.
        import gzip
        with patch.object(sys,'argv',['build','unused','base','out']), patch.object(image.legacy,'reserve_output'), patch.object(build.inspect_bundle,'inspect',return_value={}), patch.object(image,'read_regular',return_value=gzip.compress(b'x')), patch.object(image.legacy,'read_regular',return_value=gzip.compress(b'x')), patch.object(gzip,'decompress',side_effect=AssertionError('unbounded gzip reread')):
            with self.assertRaises(ValueError): build.main()
if __name__=='__main__':unittest.main()
