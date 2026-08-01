"""End-to-end: OSM fixture -> pack -> resources -> generated Monkey C."""

import base64
import json
import os
import re
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from mappack import classify, geom, osmread  # noqa: E402
from mappack.decode import decode_block  # noqa: E402
from mappack.emit import write_pack  # noqa: E402
from mappack.pack import CLIP_BUFFER, EXTENT, PackOptions, pack  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "demo-city.osm")


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


class TestReader(unittest.TestCase):
    def test_fixture_parses(self):
        with open(FIXTURE, "rb") as fh:
            ways = osmread.read_osm_xml(fh)
        self.assertGreater(len(ways), 40)
        self.assertTrue(any(w.tags.get("highway") == "motorway" for w in ways))
        self.assertTrue(any(w.tags.get("natural") == "water" and w.closed for w in ways))
        for way in ways:
            self.assertGreaterEqual(len(way.coords), 2)


class TestPack(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(FIXTURE, "rb") as fh:
            cls.ways = osmread.read_osm_xml(fh)
        cls.options = PackOptions(data_zooms=(12, 14, 16), name="Demo City")
        cls.result = pack(cls.ways, cls.options)

    def test_produces_blocks_at_every_zoom(self):
        zooms = {z for z, _bx, _by in self.result.blocks}
        self.assertEqual(zooms, {12, 14, 16})

    def test_bounds_cover_the_fixture(self):
        west, south, east, north = self.result.bounds
        self.assertLess(west, -3.70)
        self.assertGreater(east, -3.70)
        self.assertLess(south, 40.42)
        self.assertGreater(north, 40.41)

    def test_higher_zoom_has_more_tiles(self):
        counts = self.result.tile_counts
        self.assertLess(counts[12], counts[14])
        self.assertLess(counts[14], counts[16])

    def test_lower_zoom_drops_minor_roads(self):
        """z12 must not contain footways -- they are minzoom 15."""
        seen = {}
        for (zoom, _bx, _by), data in self.result.blocks.items():
            _header, tiles = decode_block(data)
            for layers in tiles.values():
                for layer_id, _feats in layers:
                    seen.setdefault(zoom, set()).add(layer_id)
        self.assertNotIn(classify.L_PATH, seen[12])
        self.assertIn(classify.L_PATH, seen[16])
        self.assertIn(classify.L_MOTORWAY, seen[12])

    def test_every_block_decodes_and_agrees_with_its_header(self):
        for (zoom, block_x, block_y), data in self.result.blocks.items():
            header, tiles = decode_block(data)
            self.assertEqual(header.zoom, zoom)
            self.assertEqual(header.block_x, block_x)
            self.assertEqual(header.block_y, block_y)
            self.assertEqual(header.block_log2, self.result.block_log2[zoom])
            self.assertEqual(header.tile_count, len(tiles))
            span = 1 << header.block_log2
            for local_x, local_y in tiles:
                self.assertLess(local_x, span)
                self.assertLess(local_y, span)

    def test_coordinates_stay_inside_the_clip_buffer(self):
        lo, hi = -CLIP_BUFFER - 2, EXTENT + CLIP_BUFFER + 2
        for data in self.result.blocks.values():
            _header, tiles = decode_block(data)
            for layers in tiles.values():
                for _layer_id, feats in layers:
                    for _geom_type, points in feats:
                        for x, y in points:
                            self.assertGreaterEqual(x, lo)
                            self.assertLessEqual(x, hi)
                            self.assertGreaterEqual(y, lo)
                            self.assertLessEqual(y, hi)

    def test_blocks_stay_addressable_by_u16_offsets(self):
        for data in self.result.blocks.values():
            self.assertLess(len(data), 65536)

    def test_point_budget_is_respected(self):
        options = PackOptions(data_zooms=(16,), max_points_per_tile=120)
        result = pack(self.ways, options)
        for data in result.blocks.values():
            _header, tiles = decode_block(data)
            for layers in tiles.values():
                total = sum(len(points) for _lid, feats in layers for _g, points in feats)
                self.assertLessEqual(total, 120)

    def test_tighter_simplification_yields_fewer_bytes(self):
        loose = pack(self.ways, PackOptions(data_zooms=(16,), simplify_px=4.0))
        tight = pack(self.ways, PackOptions(data_zooms=(16,), simplify_px=0.25))
        self.assertLess(sum(len(b) for b in loose.blocks.values()),
                        sum(len(b) for b in tight.blocks.values()))

    def test_geometry_lands_where_the_source_says(self):
        """Decode one motorway point back to lon/lat and compare with the OSM way."""
        source = next(w for w in self.ways if w.tags.get("highway") == "motorway")
        zoom = 16
        log2 = self.result.block_log2[zoom]
        found = False
        target_x = geom.lon_to_world_x(source.coords[0][0], zoom)
        target_y = geom.lat_to_world_y(source.coords[0][1], zoom)

        for (z, block_x, block_y), data in self.result.blocks.items():
            if z != zoom:
                continue
            _header, tiles = decode_block(data)
            for (local_x, local_y), layers in tiles.items():
                tile_x = (block_x << log2) + local_x
                tile_y = (block_y << log2) + local_y
                for layer_id, feats in layers:
                    if layer_id != classify.L_MOTORWAY:
                        continue
                    for _geom_type, points in feats:
                        for px, py in points:
                            world_x = tile_x * geom.TILE_SIZE + px * geom.TILE_SIZE / float(EXTENT)
                            world_y = tile_y * geom.TILE_SIZE + py * geom.TILE_SIZE / float(EXTENT)
                            if abs(world_x - target_x) < 2.0 and abs(world_y - target_y) < 2.0:
                                found = True
        self.assertTrue(found, "motorway start point should survive packing within 2 px")


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
