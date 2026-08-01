"""Integration: OSM fixture -> classify -> geom -> pack.

Runs the packing pipeline over ``tests/demo-city.osm`` and asserts on the blocks
that come out: zoom coverage, bounds, the minzoom filter, the clip buffer, the
per-tile point budget, and that geometry still lands where the source said.
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)

from mappack import classify, geom, osmread  # noqa: E402
from mappack.decode import decode_block  # noqa: E402
from mappack.pack import CLIP_BUFFER, EXTENT, PackOptions, pack  # noqa: E402

FIXTURE = os.path.join(TESTS, "demo-city.osm")


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
        self.assertLess(west, 13.37)
        self.assertGreater(east, 13.37)
        self.assertLess(south, 52.52)
        self.assertGreater(north, 52.51)

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


if __name__ == "__main__":
    unittest.main()
