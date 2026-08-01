"""Unit tests for ``mappack/osmread.py`` -- OSM input into tagged ways.

Driven by the synthetic fixture in ``tests/demo-city.osm``, which is generated
by ``tests/make_fixture.py``.
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)

from mappack import osmread  # noqa: E402

FIXTURE = os.path.join(TESTS, "demo-city.osm")


class TestReader(unittest.TestCase):
    def test_fixture_parses(self):
        with open(FIXTURE, "rb") as fh:
            ways = osmread.read_osm_xml(fh)
        self.assertGreater(len(ways), 40)
        self.assertTrue(any(w.tags.get("highway") == "motorway" for w in ways))
        self.assertTrue(any(w.tags.get("natural") == "water" and w.closed for w in ways))
        for way in ways:
            self.assertGreaterEqual(len(way.coords), 2)


if __name__ == "__main__":
    unittest.main()
