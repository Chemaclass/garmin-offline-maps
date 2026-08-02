"""Unit tests for ``mappack/classify.py`` -- OSM tags to render layer.

The layer ids asserted here are also array indices into ``source/Palette.mc``;
``test_preview.py`` guards that half of the contract.
"""

import os
import re
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

    def _alternation(self, query, key):
        """The value list the query sends for one tag key."""
        match = re.search(r'\["%s"~"\^\(([^)]*)\)\$"\]' % key, query)
        self.assertIsNotNone(match, "no %s value filter in the query" % key)
        return set(match.group(1).split("|"))

    def test_query_asks_for_exactly_the_tags_the_classifier_keeps(self):
        """The filters are generated from the classifier's own sets.

        Re-typing the values into the query is how it starts fetching tags the
        packer drops, or stops fetching ones it needs -- silently, because a
        missing way looks the same as a place with no railways in it. Reaching
        for the private sets is the point: this test exists to prove the query
        is built from them.
        """
        query = classify.build_overpass_query(40.0, -3.8, 40.5, -3.6)

        railway = self._alternation(query, "railway")
        self.assertEqual(railway, classify._RAILWAY)
        for value in railway:
            self.assertIsNotNone(classify.classify({"railway": value}), value)

        natural = self._alternation(query, "natural")
        self.assertLessEqual(classify._WATER_NATURAL, natural)
        self.assertLessEqual(classify._GREEN_NATURAL, natural)
        self.assertIn("coastline", natural)
        for value in natural:
            self.assertIsNotNone(classify.classify({"natural": value}), value)

    def test_relation_leisure_stays_inside_what_the_classifier_keeps(self):
        """The one value list still written by hand.

        Relations are fetched only for leisure areas big enough to be mapped as
        one, so this list is a deliberate subset rather than a derived one. It
        still has to name values `classify` accepts, or the query pays Overpass
        for ways that get dropped on arrival.
        """
        query = classify.build_overpass_query(40.0, -3.8, 40.5, -3.6)
        for value in self._alternation(query, "leisure"):
            self.assertIn(value, classify._GREEN_LEISURE)
            self.assertIsNotNone(classify.classify({"leisure": value}), value)


if __name__ == "__main__":
    unittest.main()
