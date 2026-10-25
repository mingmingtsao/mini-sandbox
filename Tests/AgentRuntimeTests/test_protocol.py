import pathlib
import sys
import unittest
import struct

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'Tools/AgentRuntime'))
try:
    from protocol import Parser, encode
except ImportError:

    class Parser:
        def feed(self, b):
            return []

    def encode(x):
        return b''


class ProtocolTests(unittest.TestCase):
    def test_oversize_poison(self):
        p = Parser()
        with self.assertRaises(ValueError):
            p.feed(struct.pack('>I', 16385))
        with self.assertRaises(ValueError):
            p.feed(encode({'v': 1, 'type': 'cancel', 'id': 1}))

    def test_fragmented_roundtrip(self):
        p = Parser()
        b = encode({'v': 1, 'type': 'cancel', 'id': 1})
        self.assertEqual(p.feed(b[:3]), [])
        self.assertEqual(p.feed(b[3:]), [{'v': 1, 'type': 'cancel', 'id': 1}])

    def test_reject_duplicate_json_keys(self):
        p = Parser()
        b = b'{"v":1,"v":1,"type":"cancel","id":1}'
        with self.assertRaises(ValueError):
            p.feed(struct.pack('>I', len(b)) + b)

    def test_reject_boolean_version(self):
        with self.assertRaises(ValueError):
            encode({'v': True, 'type': 'cancel', 'id': 1})

    def test_invalid_type(self):
        with self.assertRaises(ValueError):
            encode({'v': 1, 'type': 'url', 'id': 1})


if __name__ == '__main__':
    unittest.main()
