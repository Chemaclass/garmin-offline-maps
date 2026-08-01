"""Contract: the writer and the reference reader agree byte for byte.

``mappack/pack.py`` writes blocks; ``mappack/decode.py`` reads them back. The
point is not that decode works -- it is that ``decode.py`` is a deliberate
line-by-line mirror of ``source/TileReader.mc``, the one parser CI cannot
execute. If these pass, the watch is reading the bytes the packer wrote.

Spec: docs/FORMAT.md. Change one implementation and you change all three.
"""

import os
import random
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)

from mappack.decode import decode_block, decode_tile  # noqa: E402
from mappack.pack import (  # noqa: E402
    EXTENT,
    TileFeature,
    encode_block,
    encode_tile,
)


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
