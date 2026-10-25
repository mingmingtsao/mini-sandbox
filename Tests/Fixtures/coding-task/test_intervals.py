import unittest

from intervals import closed_interval


class ClosedIntervalTests(unittest.TestCase):
    def test_ascending_endpoints(self):
        self.assertEqual(closed_interval(2, 5), [2, 3, 4, 5])

    def test_single_value(self):
        self.assertEqual(closed_interval(0, 0), [0])

    def test_negative_endpoints(self):
        self.assertEqual(closed_interval(-3, -1), [-3, -2, -1])

    def test_reversed_interval_is_empty(self):
        self.assertEqual(closed_interval(5, 2), [])


if __name__ == "__main__":
    unittest.main()
