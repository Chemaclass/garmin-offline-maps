"""Unit tests for ``mappack/classify.py`` -- OSM tags to render layer.

The layer ids asserted here are also array indices into ``source/Palette.mc``;
``test_preview.py`` guards that half of the contract.
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)

from mappack import classify  # noqa: E402


class TestClassify(unittest.TestCase):
    def test_road_hierarchy_minzooms_increase_downwards(self):
        motorway = classify.classify({"highway": "motorway"})
        primary = classify.classify({"highway": "primary"})
        residential = classify.classify({"highway": "residential"})
        service = classify.classify({"highway": "service"})
        self.assertLess(motorway.minzoom, primary.minzoom)
        self.assertLess(primary.minzoom, residential.minzoom)
        self.assertLess(residential.minzoom, service.minzoom)

    def test_layer_ids_follow_draw_order(self):
        self.assertLess(classify.classify({"natural": "water"}).layer,
                        classify.classify({"highway": "residential"}).layer)
        self.assertLess(classify.classify({"highway": "residential"}).layer,
                        classify.classify({"highway": "motorway"}).layer)

    def test_water_and_park_are_polygons(self):
        self.assertEqual(classify.classify({"natural": "water"}).geom, classify.GEOM_POLYGON)
        self.assertEqual(classify.classify({"leisure": "park"}).geom, classify.GEOM_POLYGON)
        self.assertEqual(classify.classify({"waterway": "river"}).geom, classify.GEOM_LINE)

    def test_buildings_are_opt_in(self):
        self.assertIsNone(classify.classify({"building": "yes"}))
        self.assertIsNotNone(classify.classify({"building": "yes"}, include_buildings=True))

    def test_untagged_and_unknown_are_dropped(self):
        self.assertIsNone(classify.classify({}))
        self.assertIsNone(classify.classify({"amenity": "cafe"}))
        self.assertIsNone(classify.classify({"highway": "bus_stop"}))

    def test_tunnels_are_demoted(self):
        plain = classify.classify({"highway": "primary"})
        tunnel = classify.classify({"highway": "primary", "tunnel": "yes"})
        self.assertGreater(tunnel.minzoom, plain.minzoom)
        self.assertLess(tunnel.importance, plain.importance)

    def test_overpass_query_is_well_formed(self):
        query = classify.build_overpass_query(40.0, -3.8, 40.5, -3.6)
        self.assertIn("[out:xml]", query)
        self.assertIn("40.000000,-3.800000,40.500000,-3.600000", query)
        self.assertEqual(query.count("("), query.count(")"))


if __name__ == "__main__":
    unittest.main()
