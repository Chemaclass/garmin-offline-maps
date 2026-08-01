"""Unit tests for ``mappack/citypack.py`` -- downloadable city packs.

The point of these is the budget. A city that overruns Application.Storage
must fail here, in the packer, rather than half-download onto a watch.
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)
from mappack import citypack  # noqa: E402
from mappack.pack import PackOptions, PackResult  # noqa: E402


def result_with(blocks, zoom=14):
    """A PackResult carrying the given block payloads at one zoom."""
    return PackResult(
        blocks={(zoom, 100 + i, 200): payload for i, payload in enumerate(blocks)},
        block_log2={zoom: 2},
        bounds=(13.30, 52.47, 13.48, 52.56),
        center=(13.39, 52.51),
        tile_counts={zoom: len(blocks)},
        dropped_points=0,
        total_points=1000,
    )


class TestBudget(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.options = citypack.download_options("Testville")

    def test_a_block_over_the_value_limit_is_refused(self):
        oversize = b"x" * (citypack.MAX_BLOCK_BINARY + 1)
        with self.assertRaises(citypack.TooBig) as caught:
            citypack.write_city(result_with([oversize]), self.options,
                                "testville", self.dir, "(c) OSM")
        self.assertIn("storage limit", str(caught.exception))

    def test_a_block_at_the_limit_is_accepted(self):
        ok = b"x" * citypack.MAX_BLOCK_BINARY
        entry = citypack.write_city(result_with([ok]), self.options,
                                    "testville", self.dir, "(c) OSM")
        self.assertEqual(entry["blocks"], 1)

    def test_too_many_blocks_overrun_the_total_budget(self):
        # Each block is legal on its own; together they are not.
        block = b"y" * citypack.MAX_BLOCK_BINARY
        count = citypack.STORAGE_BUDGET // citypack.MAX_BLOCK_BINARY + 4
        with self.assertRaises(citypack.TooBig) as caught:
            citypack.write_city(result_with([block] * count), self.options,
                                "testville", self.dir, "(c) OSM")
        self.assertIn("storage budget", str(caught.exception))

    def test_base64_expansion_is_accounted_for(self):
        # 3 binary bytes become 4 stored bytes; the budget is about the latter.
        entry = citypack.write_city(result_with([b"z" * 300]), self.options,
                                    "testville", self.dir, "(c) OSM")
        self.assertEqual(entry["storedBytes"], 400)


class TestLayout(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.options = citypack.download_options("Berlin")
        self.entry = citypack.write_city(result_with([b"a" * 100, b"b" * 120]),
                                         self.options, "berlin", self.dir,
                                         "(c) OpenStreetMap contributors")

    def meta(self):
        with open(os.path.join(self.dir, "berlin", "meta.json"), encoding="utf-8") as fh:
            return json.load(fh)

    def test_writes_one_file_per_block_plus_meta(self):
        files = sorted(os.listdir(os.path.join(self.dir, "berlin")))
        self.assertEqual(files, ["b0.json", "b1024.json", "meta.json"])

    def test_meta_lists_every_block_key(self):
        meta = self.meta()
        self.assertEqual(sorted(meta["blocks"]), [0, 1024])

    def test_block_keys_match_the_watch_side_formula(self):
        # MapIndex.blockResource computes (relX << KEY_SHIFT) | relY. Blocks at
        # x=100 and x=101 with origin 100 must therefore be 0 and 1<<10.
        self.assertEqual(citypack.block_key(0, 100, 200, 100, 200), 0)
        self.assertEqual(citypack.block_key(0, 101, 200, 100, 200), 1024)

    def test_a_block_outside_the_key_range_is_refused(self):
        with self.assertRaises(ValueError):
            citypack.block_key(0, 99, 200, 100, 200)

    def test_meta_carries_what_the_renderer_needs(self):
        meta = self.meta()
        for key in ("dataZooms", "blockLog2", "originX", "originY", "keyShift",
                    "west", "south", "east", "north", "centerLat", "centerLon",
                    "minZoom", "maxZoom", "name", "attribution"):
            self.assertIn(key, meta)
        self.assertEqual(meta["name"], "Berlin")
        self.assertEqual(meta["dataZooms"], [14])

    def test_block_file_is_an_object_the_watch_callback_can_type(self):
        # An object, not an array: makeWebRequest types its callback data as
        # Dictionary or String or Null, so an array branch is unreachable.
        with open(os.path.join(self.dir, "berlin", "b0.json"), encoding="utf-8") as fh:
            payload = json.load(fh)
        self.assertIsInstance(payload, dict)
        self.assertIn("b", payload)


class TestCatalogueAndSettings(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.entries = [
            {"slug": "madrid", "name": "Madrid", "lat": 40.4, "lon": -3.7,
             "blocks": 9, "storedBytes": 40000},
            {"slug": "berlin", "name": "Berlin", "lat": 52.5, "lon": 13.4,
             "blocks": 12, "storedBytes": 50000},
        ]

    def test_catalogue_is_sorted_by_name(self):
        path = citypack.write_catalogue(self.entries, self.dir, "https://example.test/")
        with open(path, encoding="utf-8") as fh:
            payload = json.load(fh)
        self.assertEqual([c["name"] for c in payload["cities"]], ["Berlin", "Madrid"])
        self.assertEqual(payload["baseUrl"], "https://example.test")

    def test_settings_xml_offers_a_text_field_not_a_baked_in_list(self):
        # A dropdown would need an app update to add a city, which defeats the
        # point; it would also have to be numeric, see write_settings_xml.
        path = os.path.join(self.dir, "settings.xml")
        citypack.write_settings_xml(self.entries, path, "https://example.test")
        xml = open(path, encoding="utf-8").read()
        self.assertIn("@Properties.cityId", xml)
        self.assertIn('type="alphaNumeric"', xml)
        self.assertNotIn("listEntry", xml)

    def test_properties_xml_carries_the_base_url(self):
        path = os.path.join(self.dir, "properties.xml")
        citypack.write_properties_xml(path, "https://example.test/packs")
        xml = open(path, encoding="utf-8").read()
        self.assertIn('id="cityId"', xml)
        self.assertIn("https://example.test/packs", xml)


class TestProfile(unittest.TestCase):
    def test_block_target_keeps_base64_under_the_value_limit(self):
        encoded = citypack.MAX_BLOCK_BINARY * 4 / 3
        self.assertLess(encoded, citypack.MAX_STORAGE_VALUE)

    def test_download_options_use_a_single_zoom(self):
        options = citypack.download_options("X")
        self.assertIsInstance(options, PackOptions)
        self.assertEqual(len(options.data_zooms), 1)
        self.assertEqual(options.block_target_bytes, citypack.MAX_BLOCK_BINARY)


if __name__ == "__main__":
    unittest.main()
