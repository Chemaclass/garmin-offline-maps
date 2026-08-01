"""Format-level tests: varints, geometry helpers, and the binary round trip.

The round-trip tests matter more than they look. ``mappack/decode.py`` is a
deliberate mirror of the Monkey C reader in ``source/TileReader.mc``; if these
pass, the watch-side parser is reading the same bytes the packer wrote.
"""

import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from mappack import geom  # noqa: E402
from mappack.decode import decode_block, decode_tile  # noqa: E402
from mappack.pack import (  # noqa: E402
    EXTENT,
    TileFeature,
    encode_block,
    encode_tile,
)
from mappack.varint import (  # noqa: E402
    read_svarint,
    read_u16,
    read_uvarint,
    write_svarint,
    write_u16,
    write_uvarint,
    zigzag_decode,
    zigzag_encode,
)


class TestVarint(unittest.TestCase):
    def test_zigzag_round_trip(self):
        for value in [0, -1, 1, -2, 2, 63, -64, 1023, -1024, 65535, -65536, 2 ** 30, -(2 ** 30)]:
            self.assertEqual(zigzag_decode(zigzag_encode(value)), value)

    def test_zigzag_keeps_small_magnitudes_small(self):
        for value in range(-63, 64):
            self.assertLess(zigzag_encode(value), 128, "±63 must still fit one varint byte")

    def test_uvarint_round_trip(self):
        for value in [0, 1, 127, 128, 300, 16383, 16384, 1 << 20, (1 << 28) - 1]:
            buf = bytearray()
            write_uvarint(buf, value)
            decoded, pos = read_uvarint(bytes(buf), 0)
            self.assertEqual(decoded, value)
            self.assertEqual(pos, len(buf))

    def test_svarint_round_trip(self):
        random.seed(7)
        for _ in range(500):
            value = random.randint(-100000, 100000)
            buf = bytearray()
            write_svarint(buf, value)
            decoded, pos = read_svarint(bytes(buf), 0)
            self.assertEqual(decoded, value)
            self.assertEqual(pos, len(buf))

    def test_uvarint_rejects_negative(self):
        with self.assertRaises(ValueError):
            write_uvarint(bytearray(), -1)

    def test_u16_round_trip(self):
        for value in [0, 1, 255, 256, 65535]:
            buf = bytearray()
            write_u16(buf, value)
            self.assertEqual(read_u16(bytes(buf), 0)[0], value)

    def test_u16_rejects_overflow(self):
        with self.assertRaises(ValueError):
            write_u16(bytearray(), 65536)


class TestGeometry(unittest.TestCase):
    def test_mercator_round_trip(self):
        for lon, lat in [(0.0, 0.0), (-3.7038, 40.4168), (13.405, 52.52), (-122.4, 37.8)]:
            for zoom in (12, 14, 16):
                x = geom.lon_to_world_x(lon, zoom)
                y = geom.lat_to_world_y(lat, zoom)
                self.assertAlmostEqual(geom.world_x_to_lon(x, zoom), lon, places=6)
                self.assertAlmostEqual(geom.world_y_to_lat(y, zoom), lat, places=6)

    def test_world_size_matches_zoom(self):
        self.assertAlmostEqual(geom.lon_to_world_x(180.0, 14), 256 * (1 << 14), places=3)

    def test_meters_per_pixel_known_value(self):
        # Equator, z0, 256 px tile -> ~156543 m/px is the standard constant.
        self.assertAlmostEqual(geom.meters_per_pixel(0.0, 0), 156543.03392804097, places=3)

    def test_simplify_keeps_endpoints(self):
        points = [(0.0, 0.0), (1.0, 0.02), (2.0, -0.01), (3.0, 0.0), (4.0, 5.0)]
        out = geom.simplify(points, 0.5)
        self.assertEqual(out[0], points[0])
        self.assertEqual(out[-1], points[-1])
        self.assertLess(len(out), len(points))

    def test_simplify_preserves_sharp_corner(self):
        points = [(0.0, 0.0), (5.0, 0.0), (5.0, 5.0)]
        self.assertEqual(geom.simplify(points, 0.5), points)

    def test_simplify_is_noop_below_three_points(self):
        self.assertEqual(geom.simplify([(0.0, 0.0), (1.0, 1.0)], 10.0), [(0.0, 0.0), (1.0, 1.0)])

    def test_clip_polyline_inside(self):
        points = [(1.0, 1.0), (2.0, 2.0)]
        self.assertEqual(geom.clip_polyline(points, 0, 0, 10, 10), [points])

    def test_clip_polyline_outside(self):
        self.assertEqual(geom.clip_polyline([(20.0, 20.0), (30.0, 30.0)], 0, 0, 10, 10), [])

    def test_clip_polyline_crossing(self):
        parts = geom.clip_polyline([(-5.0, 5.0), (15.0, 5.0)], 0, 0, 10, 10)
        self.assertEqual(len(parts), 1)
        self.assertAlmostEqual(parts[0][0][0], 0.0)
        self.assertAlmostEqual(parts[0][-1][0], 10.0)

    def test_clip_polyline_splits_on_re_entry(self):
        # out -> in -> out -> in -> out should yield two separate runs
        line = [(-5.0, 5.0), (5.0, 5.0), (5.0, 20.0), (8.0, 20.0), (8.0, 5.0), (15.0, 5.0)]
        parts = geom.clip_polyline(line, 0, 0, 10, 10)
        self.assertEqual(len(parts), 2)

    def test_clip_polygon_to_rect(self):
        square = [(-5.0, -5.0), (15.0, -5.0), (15.0, 15.0), (-5.0, 15.0)]
        clipped = geom.clip_polygon(square, 0, 0, 10, 10)
        self.assertGreaterEqual(len(clipped), 4)
        for x, y in clipped:
            self.assertGreaterEqual(x, -1e-9)
            self.assertLessEqual(x, 10 + 1e-9)
            self.assertGreaterEqual(y, -1e-9)
            self.assertLessEqual(y, 10 + 1e-9)

    def test_polygon_area(self):
        self.assertAlmostEqual(geom.polygon_area([(0, 0), (4, 0), (4, 3), (0, 3)]), 12.0)


class TestTileCodec(unittest.TestCase):
    def make_features(self, seed=1):
        random.seed(seed)
        features = []
        for layer in (0, 5, 9):
            for _ in range(3):
                count = random.randint(2, 40)
                x = random.randint(-64, EXTENT + 64)
                y = random.randint(-64, EXTENT + 64)
                points = [(x, y)]
                for _ in range(count - 1):
                    x += random.randint(-90, 90)
                    y += random.randint(-90, 90)
                    points.append((x, y))
                features.append(TileFeature(layer, 0 if layer else 1, points, 50))
        return features

    def test_tile_round_trip(self):
        features = self.make_features()
        payload = encode_tile(features)
        layers = decode_tile(payload)

        expected = {}
        for feature in features:
            expected.setdefault(feature.layer, []).append((feature.geom_type, feature.points))

        self.assertEqual([layer_id for layer_id, _ in layers], sorted(expected))
        for layer_id, decoded in layers:
            self.assertEqual(decoded, expected[layer_id])

    def test_layers_are_emitted_in_draw_order(self):
        features = [
            TileFeature(9, 0, [(0, 0), (10, 10)], 100),
            TileFeature(0, 1, [(0, 0), (10, 0), (10, 10)], 90),
            TileFeature(5, 0, [(1, 1), (2, 2)], 30),
        ]
        layer_ids = [layer_id for layer_id, _ in decode_tile(encode_tile(features))]
        self.assertEqual(layer_ids, [0, 5, 9])

    def test_block_round_trip(self):
        tiles = {
            (0, 0): encode_tile(self.make_features(2)),
            (3, 5): encode_tile(self.make_features(3)),
            (7, 7): encode_tile(self.make_features(4)),
        }
        raw = encode_block(16, 3, 4011, 3088, tiles)
        header, decoded = decode_block(raw)

        self.assertEqual(header.zoom, 16)
        self.assertEqual(header.block_log2, 3)
        self.assertEqual(header.block_x, 4011)
        self.assertEqual(header.block_y, 3088)
        self.assertEqual(header.tile_count, 3)
        self.assertEqual(sorted(decoded), sorted(tiles))
        for key, payload in tiles.items():
            self.assertEqual(decoded[key], decode_tile(payload))

    def test_block_rejects_bad_magic(self):
        raw = bytearray(encode_block(12, 3, 1, 1, {(0, 0): encode_tile(self.make_features())}))
        raw[0] = 0x00
        with self.assertRaises(ValueError):
            decode_block(bytes(raw))

    def test_directory_offsets_are_monotonic(self):
        tiles = {(x, 0): encode_tile(self.make_features(x + 10)) for x in range(6)}
        raw = encode_block(14, 3, 10, 20, tiles)
        from mappack.decode import decode_directory

        offsets = [decode_directory(raw)[key] for key in sorted(tiles)]
        self.assertEqual(offsets, sorted(offsets))
        self.assertLess(max(offsets), len(raw))


if __name__ == "__main__":
    unittest.main()
