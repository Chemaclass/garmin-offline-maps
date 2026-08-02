"""Varint / zigzag primitives shared by the packer and the reference decoder.

The on-watch decoder in ``source/TileReader.mc`` implements exactly these rules.
Keep the two in sync -- ``tests/contract/test_tile_format.py`` proves they agree.
"""

from __future__ import annotations

from typing import List


def zigzag_encode(n: int) -> int:
    """Map signed -> unsigned so that small magnitudes stay small."""
    return (n << 1) ^ (-1 if n < 0 else 0)


def zigzag_decode(v: int) -> int:
    return (v >> 1) ^ -(v & 1)


def write_uvarint(out: bytearray, value: int) -> None:
    """LEB128, 7 bits per byte, high bit = continuation."""
    if value < 0:
        raise ValueError("uvarint must be non-negative, got %d" % value)
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return


def write_svarint(out: bytearray, value: int) -> None:
    write_uvarint(out, zigzag_encode(value))


def read_uvarint(buf: bytes, pos: int) -> tuple[int, int]:
    """Return (value, new_pos).

    The `shift > 35` cap is five payload bytes, which is `MapFormat`'s
    `MAX_VARINT_BYTES` in ``source/TileReader.mc``. Both sides bound the loop;
    they differ only in what they do at the limit, and they have to. Here a
    corrupt stream should stop the tool loudly. On the watch it cannot raise:
    this runs inside the render, and an unbounded loop there is not a wrong
    picture but a hung app that the watchdog kills outright. So the reader
    returns a wrong number and lets `drawTile` reject it.
    """
    result = 0
    shift = 0
    while True:
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 35:
            raise ValueError("varint too long at offset %d" % pos)


def read_svarint(buf: bytes, pos: int) -> tuple[int, int]:
    value, pos = read_uvarint(buf, pos)
    return zigzag_decode(value), pos


def write_u16(out: bytearray, value: int) -> None:
    if not 0 <= value <= 0xFFFF:
        raise ValueError("u16 out of range: %d" % value)
    out.append(value & 0xFF)
    out.append((value >> 8) & 0xFF)


def read_u16(buf: bytes, pos: int) -> tuple[int, int]:
    return buf[pos] | (buf[pos + 1] << 8), pos + 2


def encode_points(points: List[tuple[int, int]]) -> bytearray:
    """Point count + first absolute point + zigzag deltas."""
    out = bytearray()
    write_uvarint(out, len(points))
    px, py = 0, 0
    for x, y in points:
        write_svarint(out, x - px)
        write_svarint(out, y - py)
        px, py = x, y
    return out
