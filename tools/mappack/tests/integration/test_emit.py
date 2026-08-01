"""Integration: pack -> emit -> Connect IQ resources + generated Monkey C.

Covers the two artefacts the watch actually consumes: the base64 jsonData block
files declared in ``mapdata.xml``, and the generated ``MapIndex.mc`` whose
``blockResource()`` switch is re-implemented here in Python and checked mapping
by mapping.
"""

import base64
import json
import os
import re
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)

from mappack import osmread  # noqa: E402
from mappack.emit import write_pack  # noqa: E402
from mappack.pack import EXTENT, PackOptions, pack  # noqa: E402

FIXTURE = os.path.join(TESTS, "demo-city.osm")


class TestEmit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        with open(FIXTURE, "rb") as fh:
            ways = osmread.read_osm_xml(fh)
        self.options = PackOptions(data_zooms=(12, 14, 16), name="Demo City")
        self.result = pack(ways, self.options)
        self.out_dir = os.path.join(self.tmp, "active")
        self.index = os.path.join(self.tmp, "MapIndex.mc")
        self.manifest = write_pack(self.result, self.options, self.out_dir, self.index,
                                   "(c) OpenStreetMap contributors")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_every_block_has_a_json_file_that_decodes_to_its_bytes(self):
        for (zoom, block_x, block_y), data in self.result.blocks.items():
            path = os.path.join(self.out_dir, "blocks", "b%d_%d_%d.json" % (zoom, block_x, block_y))
            self.assertTrue(os.path.exists(path), path)
            with open(path, encoding="utf-8") as fh:
                payload = json.load(fh)
            self.assertIsInstance(payload, list)
            self.assertEqual(len(payload), 1)
            self.assertEqual(base64.b64decode(payload[0]), data)

    def test_resource_xml_declares_every_block(self):
        with open(os.path.join(self.out_dir, "mapdata.xml"), encoding="utf-8") as fh:
            xml = fh.read()
        import xml.etree.ElementTree as ET

        root = ET.fromstring(xml)
        ids = {node.get("id") for node in root.findall("jsonData")}
        self.assertEqual(len(ids), len(self.result.blocks))
        for node in root.findall("jsonData"):
            self.assertTrue(os.path.exists(os.path.join(self.out_dir, node.get("filename"))))

    def test_generated_index_references_only_declared_resources(self):
        with open(self.index, encoding="utf-8") as fh:
            source = fh.read()
        referenced = set(re.findall(r"Rez\.JsonData\.(\w+)", source))
        with open(os.path.join(self.out_dir, "mapdata.xml"), encoding="utf-8") as fh:
            declared = set(re.findall(r'id="(\w+)"', fh.read()))
        self.assertEqual(referenced, declared)

    def test_generated_index_lookup_matches_the_pack(self):
        """Re-implement blockResource() in Python and check every mapping."""
        with open(self.index, encoding="utf-8") as fh:
            source = fh.read()

        origins_x = [int(v) for v in re.search(r"BLOCK_ORIGIN_X = \[([^\]]*)\]", source).group(1).split(",")]
        origins_y = [int(v) for v in re.search(r"BLOCK_ORIGIN_Y = \[([^\]]*)\]", source).group(1).split(",")]
        zooms = [int(v) for v in re.search(r"DATA_ZOOMS = \[([^\]]*)\]", source).group(1).split(",")]
        shift = int(re.search(r"KEY_SHIFT = (\d+)", source).group(1))

        cases = {}
        current = None
        for line in source.splitlines():
            zoom_match = re.search(r"\(z == (\d+)\) \{", line)
            if zoom_match:
                current = int(zoom_match.group(1))
            case_match = re.search(r"case (\d+): return Rez\.JsonData\.(\w+);", line)
            if case_match and current is not None:
                cases[(current, int(case_match.group(1)))] = case_match.group(2)

        self.assertEqual(len(cases), len(self.result.blocks))
        for (zoom, block_x, block_y) in self.result.blocks:
            slot = zooms.index(zoom)
            key = ((block_x - origins_x[slot]) << shift) | (block_y - origins_y[slot])
            self.assertEqual(cases[(zoom, key)], "b%d_%d_%d" % (zoom, block_x, block_y))

    def test_manifest_totals_match_the_files_on_disk(self):
        on_disk = 0
        blocks_dir = os.path.join(self.out_dir, "blocks")
        for name in os.listdir(blocks_dir):
            with open(os.path.join(blocks_dir, name), encoding="utf-8") as fh:
                on_disk += len(json.load(fh)[0])
        self.assertEqual(on_disk, self.manifest["base64_bytes"])
        self.assertEqual(self.manifest["block_count"], len(self.result.blocks))
        self.assertEqual(self.manifest["extent"], EXTENT)

    def test_index_stays_within_the_switch_key_range(self):
        with open(self.index, encoding="utf-8") as fh:
            source = fh.read()
        for key in re.findall(r"case (\d+):", source):
            self.assertLess(int(key), 1 << 20)

    def test_rerunning_clears_stale_blocks(self):
        stale = os.path.join(self.out_dir, "blocks", "b12_999_999.json")
        with open(stale, "w", encoding="utf-8") as fh:
            fh.write('["AA=="]')
        write_pack(self.result, self.options, self.out_dir, self.index, "x")
        self.assertFalse(os.path.exists(stale))


if __name__ == "__main__":
    unittest.main()
