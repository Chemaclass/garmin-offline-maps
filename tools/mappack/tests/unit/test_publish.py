"""Unit tests for ``mappack/publish.py`` -- building the city catalogue.

No network: `build_city` takes a searcher and a loader for exactly that reason.
The slug rules matter more than they look, because the watch turns whatever
someone typed into one of these and GitHub Pages is case-sensitive.
"""

import argparse
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)
from mappack import geocode, publish  # noqa: E402
from mappack.osmread import Way  # noqa: E402


class TestSlugify(unittest.TestCase):
    def test_lowercases(self):
        self.assertEqual(publish.slugify("Berlin"), "berlin")

    def test_spaces_become_hyphens(self):
        self.assertEqual(publish.slugify("New York"), "new-york")

    def test_punctuation_and_accents_collapse(self):
        self.assertEqual(publish.slugify("München, Bayern"), "m-nchen-bayern")

    def test_no_leading_or_trailing_separator(self):
        self.assertEqual(publish.slugify("  Madrid  "), "madrid")

    def test_never_returns_empty(self):
        self.assertEqual(publish.slugify("---"), "city")


def grid_ways(lat, lon, span=0.02, rows=6):
    """A small road grid around a point, enough to pack."""
    ways = []
    for i in range(rows):
        offset = span * i / (rows - 1) - span / 2
        ways.append(Way(tags={"highway": "primary"},
                        coords=[(lon - span, lat + offset), (lon + span, lat + offset)]))
        ways.append(Way(tags={"highway": "secondary"},
                        coords=[(lon + offset, lat - span), (lon + offset, lat + span)]))
    return ways


class TestBuildCity(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.args = argparse.Namespace(
            out=self.dir, radius_km=6.0, attribution="(c) OSM",
            cache_dir=None, overpass_url="http://unused.test",
        )

    def searcher(self, name="Madrid, Spain", lat=40.4168, lon=-3.7038):
        def search(query, url=None):
            return [geocode.Place(name, lat, lon, (lon - 0.1, lat - 0.1,
                                                   lon + 0.1, lat + 0.1), "city")]
        return search

    def loader(self, lat=40.4168, lon=-3.7038):
        def load(path, bbox, overpass_url, cache):
            load.bbox = bbox
            return grid_ways(lat, lon)
        return load

    def test_writes_a_city_and_returns_its_entry(self):
        entry = publish.build_city("Madrid", self.args,
                                   self.searcher(), self.loader())
        self.assertEqual(entry["slug"], "madrid")
        self.assertEqual(entry["name"], "Madrid")
        self.assertTrue(os.path.exists(os.path.join(self.dir, "madrid", "meta.json")))

    def test_the_bbox_comes_from_the_radius_not_the_place_boundary(self):
        # Nominatim's own boundary for a capital is tens of km across; packing
        # that is what the radius exists to prevent.
        loader = self.loader()
        publish.build_city("Madrid", self.args, self.searcher(), loader)
        west, south, east, north = loader.bbox
        self.assertAlmostEqual(geocode.span_km(south, north, None), 12.0, places=1)

    def test_no_geocoder_match_is_skipped_not_crashed(self):
        def empty(query, url=None):
            return []
        self.assertIsNone(publish.build_city("Nowhere", self.args, empty,
                                             self.loader()))

    def test_the_pack_is_named_after_the_place_not_the_query(self):
        entry = publish.build_city("madrid spain", self.args,
                                   self.searcher(), self.loader())
        self.assertEqual(entry["name"], "Madrid")
        self.assertEqual(entry["slug"], "madrid-spain")


class TestSlugOverride(unittest.TestCase):
    def test_a_bare_name_has_no_override(self):
        self.assertEqual(publish.split_entry("Berlin"), ("Berlin", None))

    def test_an_override_drops_the_geocoding_qualifier(self):
        # "Valencia" alone geocodes to the wrong country often enough to need
        # qualifying, but nobody should have to type "valencia-spain".
        self.assertEqual(publish.split_entry("Valencia, Spain | valencia"),
                         ("Valencia, Spain", "valencia"))

    def test_the_override_is_itself_slugified(self):
        self.assertEqual(publish.split_entry("X | New York")[1], "new-york")

    def test_whitespace_around_the_bar_is_optional(self):
        self.assertEqual(publish.split_entry("A, B|c"), ("A, B", "c"))


class TestCityList(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)

    def write(self, text):
        path = os.path.join(self.dir, "cities.txt")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        return path

    def test_reads_one_name_per_line(self):
        path = self.write("Berlin\nMadrid\n")
        self.assertEqual(publish.read_city_list(path), ["Berlin", "Madrid"])

    def test_ignores_comments_and_blank_lines(self):
        path = self.write("# capitals\nBerlin  \n\n  Madrid # dense\n")
        self.assertEqual(publish.read_city_list(path), ["Berlin", "Madrid"])


if __name__ == "__main__":
    unittest.main()
