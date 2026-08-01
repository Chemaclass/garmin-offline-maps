"""Reference decoder for the MapPack binary format.

This is a line-by-line mirror of ``source/TileReader.mc``. It exists so the
test suite can prove that what the packer writes is exactly what the watch
reads -- the watch-side parser is the part we cannot unit test on CI.
"""

from __future__ import annotations

from typing import Dict, List, NamedTuple, Tuple

from .varint import read_svarint, read_u16, read_uvarint

MAGIC = 0x4D


class BlockHeader(NamedTuple):
    version: int
    zoom: int
    block_log2: int
    block_x: int
    block_y: int
    tile_count: int


def decode_block_header(data: bytes) -> BlockHeader:
    if not data or data[0] != MAGIC:
        raise ValueError("not a MapPack block (bad magic)")
    block_x, _ = read_u16(data, 4)
    block_y, _ = read_u16(data, 6)
    return BlockHeader(
        version=data[1],
        zoom=data[2],
        block_log2=data[3],
        block_x=block_x,
        block_y=block_y,
        tile_count=data[8],
    )


def decode_directory(data: bytes) -> Dict[Tuple[int, int], int]:
    """Return {(local_x, local_y): payload_offset}."""
    header = decode_block_header(data)
    out: Dict[Tuple[int, int], int] = {}
    pos = 9
    for _ in range(header.tile_count):
        local_x = data[pos]
        local_y = data[pos + 1]
        offset, _ = read_u16(data, pos + 2)
        out[(local_x, local_y)] = offset
        pos += 4
    return out


def decode_tile(payload: bytes, pos: int = 0) -> List[Tuple[int, List[Tuple[int, List[Tuple[int, int]]]]]]:
    """Return [(layer_id, [(geom_type, [(x, y), ...]), ...]), ...]."""
    layers: List[Tuple[int, List[Tuple[int, List[Tuple[int, int]]]]]] = []
    layer_count = payload[pos]
    pos += 1
    for _ in range(layer_count):
        layer_id = payload[pos]
        layer_bytes, pos = read_u16(payload, pos + 1)
        layer_end = pos + layer_bytes
        feature_count = payload[pos]
        pos += 1
        features: List[Tuple[int, List[Tuple[int, int]]]] = []
        for _ in range(feature_count):
            geom_type = payload[pos]
            pos += 1
            point_count, pos = read_uvarint(payload, pos)
            points: List[Tuple[int, int]] = []
            x = y = 0
            for _ in range(point_count):
                dx, pos = read_svarint(payload, pos)
                dy, pos = read_svarint(payload, pos)
                x += dx
                y += dy
                points.append((x, y))
            features.append((geom_type, points))
        if pos != layer_end:
            raise ValueError(
                "layer %d declared %d bytes but consumed %d"
                % (layer_id, layer_bytes, layer_bytes - (layer_end - pos))
            )
        layers.append((layer_id, features))
    return layers


def decode_block(data: bytes):
    """Return (header, {(local_x, local_y): decoded_tile})."""
    header = decode_block_header(data)
    tiles = {}
    for key, offset in decode_directory(data).items():
        tiles[key] = decode_tile(data, offset)
    return header, tiles
