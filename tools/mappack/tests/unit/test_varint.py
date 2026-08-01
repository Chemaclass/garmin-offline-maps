"""Unit tests for ``mappack/varint.py`` -- LEB128 and zigzag primitives.

These underpin the whole format: every coordinate in a tile is a zigzag varint,
and ``source/TileReader.mc`` implements the same two routines by hand.
"""

import os
import random
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)

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


if __name__ == "__main__":
    unittest.main()
