"""Turn OSM ways into a MapPack: binary vector tiles grouped into blocks.

Binary layout (little-endian, all offsets from the start of the block):

    block
      u8   magic  'M' (0x4D)
      u8   format version
      u8   zoom
      u8   block_log2          (block covers 2**block_log2 tiles per axis)
      u16  block_x             (tile_x >> block_log2)
      u16  block_y
      u8   tile_count
      tile_count x directory entry:
        u8   local_x           (0 .. 2**block_log2 - 1)
        u8   local_y
        u16  offset            (byte offset of this tile's payload)
      ... tile payloads ...

    tile payload
      u8   layer_count
      layer_count x:
        u8       layer_id            (ascending == draw order)
        u16      layer_bytes         (size of everything after this field)
        u8       feature_count
        feature_count x:
          u8       geometry type (0 = polyline, 1 = polygon)
          uvarint  point_count
          point_count x (svarint dx, svarint dy)   -- first delta is from (0,0)

``layer_bytes`` exists so the renderer can skip a layer without walking its
varints: it draws filled areas for every visible tile first, then strokes, so
a lake in one tile cannot paint over a road in its neighbour.

Coordinates are tile-local in a 0..EXTENT grid, allowed to run slightly
negative / past EXTENT because geometry is clipped with a small buffer so
strokes do not end abruptly at tile seams.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

from . import geom
from .classify import GEOM_POLYGON, L_BUILDING, Klass, classify
from .decode import decode_tile
from .varint import encode_points, write_u16, write_uvarint

FORMAT_VERSION = 1
MAGIC = 0x4D
EXTENT = 1024
#: clip buffer in tile-local units (1024 extent over a 256 px tile -> 4 units/px)
CLIP_BUFFER = 64
UNITS_PER_PIXEL = EXTENT // geom.TILE_SIZE

MAX_BLOCK_BYTES = 60000  # u16 offsets + a comfortable margin under 64 KB
MAX_FEATURES_PER_LAYER = 255

#: Largest share of a tile's point budget that filled areas may take.
#:
#: Areas outrank minor roads on importance (green is 50, residential 45), and
#: among equal importance the biggest feature is taken first. In a place ringed
#: by farmland that is a disaster: one huerta polygon swallows what is left of
#: the budget and the street network gets nothing, which is how Murcia packed
#: as a green field with no roads on it. Reserving the rest for lines means a
#: map you can still navigate by, whatever the landcover looks like.
AREA_BUDGET_SHARE = 0.35

#: magic, version, zoom, block_log2, u16 block_x, u16 block_y, tile count.
#: Mirrors `MapFormat.HEADER_BYTES` in source/TileReader.mc.
HEADER_BYTES = 9
#: local_x, local_y, u16 payload offset. Mirrors `MapFormat.DIRECTORY_ENTRY_BYTES`.
DIRECTORY_ENTRY_BYTES = 4


@dataclass
class Feature:
    klass: Klass
    #: world-pixel coordinates at ``ref_zoom``
    coords: List[Tuple[float, float]]
    length: float


@dataclass
class TileFeature:
    layer: int
    geom_type: int
    points: List[Tuple[int, int]]
    importance: int


@dataclass
class PackOptions:
    data_zooms: Sequence[int] = (12, 14, 16)
    min_display_zoom: int = 11
    max_display_zoom: int = 17
    simplify_px: float = 1.0
    max_points_per_tile: int = 1100
    include_buildings: bool = False
    resource_budget: int = 200
    name: str = "map"
    #: Block size to aim for. Compiled-in packs use the default; a downloadable
    #: pack passes something much smaller, because every block has to base64
    #: under Application.Storage's 8 KB per-value ceiling. See citypack.py.
    block_target_bytes: int = 0


@dataclass
class PackResult:
    blocks: Dict[Tuple[int, int, int], bytes]  # (zoom, block_x, block_y) -> bytes
    block_log2: Dict[int, int]                 # zoom -> block_log2
    bounds: Tuple[float, float, float, float]  # min_lon, min_lat, max_lon, max_lat
    center: Tuple[float, float]
    tile_counts: Dict[int, int]
    dropped_points: int
    total_points: int


# ---------------------------------------------------------------------------
# stage 1: OSM ways -> classified features in world pixels at the top zoom
# ---------------------------------------------------------------------------


def build_features(ways, options: PackOptions, ref_zoom: int) -> List[Feature]:
    features: List[Feature] = []
    for way in ways:
        klass = classify(way.tags, options.include_buildings)
        if klass is None:
            continue
        coords = geom.project(way.coords, ref_zoom)
        if klass.geom == GEOM_POLYGON:
            if len(coords) < 3:
                continue
            if coords[0] != coords[-1]:
                coords = coords + [coords[0]]
            size = geom.polygon_area(coords)
        else:
            if len(coords) < 2:
                continue
            size = geom.polyline_length(coords)
        features.append(Feature(klass=klass, coords=coords, length=size))
    return features


def clamp_bbox(features: Sequence[Feature], ref_zoom: int):
    if not features:
        raise SystemExit("No renderable features found -- check your bbox or input file.")
    min_x = min(min(p[0] for p in f.coords) for f in features)
    max_x = max(max(p[0] for p in f.coords) for f in features)
    min_y = min(min(p[1] for p in f.coords) for f in features)
    max_y = max(max(p[1] for p in f.coords) for f in features)
    return (
        geom.world_x_to_lon(min_x, ref_zoom),
        geom.world_y_to_lat(max_y, ref_zoom),
        geom.world_x_to_lon(max_x, ref_zoom),
        geom.world_y_to_lat(min_y, ref_zoom),
    )


# ---------------------------------------------------------------------------
# stage 2: features -> tiles
# ---------------------------------------------------------------------------


def _to_local(points, tile_x: int, tile_y: int) -> List[Tuple[int, int]]:
    ox = tile_x * geom.TILE_SIZE
    oy = tile_y * geom.TILE_SIZE
    out: List[Tuple[int, int]] = []
    for x, y in points:
        lx = int(round((x - ox) * UNITS_PER_PIXEL))
        ly = int(round((y - oy) * UNITS_PER_PIXEL))
        if out and out[-1] == (lx, ly):
            continue
        out.append((lx, ly))
    return out


def build_tiles(
    features: Sequence[Feature], zoom: int, ref_zoom: int, options: PackOptions,
    bounds_tiles: Optional[Tuple[int, int, int, int]] = None,
) -> Tuple[Dict[Tuple[int, int], List[TileFeature]], int, int]:
    """Return ({(tile_x, tile_y): [TileFeature]}, kept_points, dropped_points)."""
    scale = 1.0 / (1 << (ref_zoom - zoom))
    tolerance = options.simplify_px
    buffer_px = CLIP_BUFFER / UNITS_PER_PIXEL

    candidates: Dict[Tuple[int, int], List[TileFeature]] = {}

    for feature in features:
        if feature.klass.minzoom > zoom:
            continue
        pts = [(x * scale, y * scale) for x, y in feature.coords]
        is_polygon = feature.klass.geom == GEOM_POLYGON
        pts = geom.simplify(pts, tolerance)
        if is_polygon:
            if len(pts) < 4:
                continue
            # Drop areas that would be sub-pixel at this zoom.
            if geom.polygon_area(pts) < 12.0:
                continue
        elif len(pts) < 2:
            continue

        min_x, min_y, max_x, max_y = geom.bbox(pts)
        tx0 = int(math.floor((min_x - buffer_px) / geom.TILE_SIZE))
        tx1 = int(math.floor((max_x + buffer_px) / geom.TILE_SIZE))
        ty0 = int(math.floor((min_y - buffer_px) / geom.TILE_SIZE))
        ty1 = int(math.floor((max_y + buffer_px) / geom.TILE_SIZE))
        if bounds_tiles is not None:
            bx0, by0, bx1, by1 = bounds_tiles
            tx0, tx1 = max(tx0, bx0), min(tx1, bx1)
            ty0, ty1 = max(ty0, by0), min(ty1, by1)

        for tile_x in range(tx0, tx1 + 1):
            x_lo = tile_x * geom.TILE_SIZE - buffer_px
            x_hi = (tile_x + 1) * geom.TILE_SIZE + buffer_px
            for tile_y in range(ty0, ty1 + 1):
                y_lo = tile_y * geom.TILE_SIZE - buffer_px
                y_hi = (tile_y + 1) * geom.TILE_SIZE + buffer_px
                if is_polygon:
                    clipped = geom.clip_polygon(pts, x_lo, y_lo, x_hi, y_hi)
                    if len(clipped) < 3:
                        continue
                    parts = [clipped]
                else:
                    parts = geom.clip_polyline(pts, x_lo, y_lo, x_hi, y_hi)
                for part in parts:
                    local = _to_local(part, tile_x, tile_y)
                    if is_polygon:
                        if len(local) > 1 and local[0] == local[-1]:
                            local = local[:-1]
                        if len(local) < 3:
                            continue
                    elif len(local) < 2:
                        continue
                    candidates.setdefault((tile_x, tile_y), []).append(
                        TileFeature(
                            layer=feature.klass.layer,
                            geom_type=feature.klass.geom,
                            points=local,
                            importance=feature.klass.importance,
                        )
                    )

    kept_points = 0
    dropped_points = 0
    tiles: Dict[Tuple[int, int], List[TileFeature]] = {}
    for key, feats in candidates.items():
        feats.sort(key=lambda f: (-f.importance, -len(f.points)))
        budget = options.max_points_per_tile
        area_budget = int(options.max_points_per_tile * AREA_BUDGET_SHARE)
        per_layer: Dict[int, int] = {}
        chosen: List[TileFeature] = []
        for feat in feats:
            count = per_layer.get(feat.layer, 0)
            if count >= MAX_FEATURES_PER_LAYER:
                dropped_points += len(feat.points)
                continue
            if len(feat.points) > budget:
                dropped_points += len(feat.points)
                continue
            # Filled areas draw first and cover everything under them, so they
            # are capped separately. Without this they starve the roads drawn
            # on top; see AREA_BUDGET_SHARE.
            is_area = feat.layer <= L_BUILDING
            if is_area:
                if len(feat.points) > area_budget:
                    dropped_points += len(feat.points)
                    continue
                area_budget -= len(feat.points)
            budget -= len(feat.points)
            per_layer[feat.layer] = count + 1
            chosen.append(feat)
            kept_points += len(feat.points)
        if chosen:
            # Draw order: ascending layer id.
            chosen.sort(key=lambda f: f.layer)
            tiles[key] = chosen
    return tiles, kept_points, dropped_points


# ---------------------------------------------------------------------------
# stage 3: tiles -> binary blocks
# ---------------------------------------------------------------------------


def encode_tile(features: Sequence[TileFeature]) -> bytes:
    by_layer: Dict[int, List[TileFeature]] = {}
    for feature in features:
        by_layer.setdefault(feature.layer, []).append(feature)

    out = bytearray()
    out.append(len(by_layer))
    for layer_id in sorted(by_layer):
        feats = by_layer[layer_id][:MAX_FEATURES_PER_LAYER]
        blob = bytearray()
        blob.append(len(feats))
        for feature in feats:
            blob.append(feature.geom_type)
            blob += encode_points(feature.points)
        out.append(layer_id)
        write_u16(out, len(blob))
        out += blob
    return bytes(out)


def encode_block(zoom: int, block_log2: int, block_x: int, block_y: int,
                 tiles: Dict[Tuple[int, int], bytes]) -> bytes:
    keys = sorted(tiles)
    if len(keys) > 255:
        raise ValueError("block holds %d tiles, max 255" % len(keys))
    header = bytearray()
    header.append(MAGIC)
    header.append(FORMAT_VERSION)
    header.append(zoom)
    header.append(block_log2)
    write_u16(header, block_x)
    write_u16(header, block_y)
    header.append(len(keys))

    directory_size = len(keys) * DIRECTORY_ENTRY_BYTES
    payload_start = len(header) + directory_size

    directory = bytearray()
    payload = bytearray()
    for local_x, local_y in keys:
        directory.append(local_x)
        directory.append(local_y)
        write_u16(directory, payload_start + len(payload))
        payload += tiles[(local_x, local_y)]

    return bytes(header + directory + payload)


def block_size(tiles: Dict[Tuple[int, int], bytes]) -> int:
    """Encoded size of a block, computed without encoding it.

    `encode_block` writes u16 payload offsets, so it raises on an oversized
    block rather than returning something a caller can measure and then shrink.
    Callers that need to decide whether to shrink must size the block first,
    and this is the one place that arithmetic lives: a 9-byte header, a 4-byte
    directory entry per tile, then the payloads.
    """
    return HEADER_BYTES + DIRECTORY_ENTRY_BYTES * len(tiles) \
        + sum(len(payload) for payload in tiles.values())


def group_into_blocks(
    encoded: Dict[Tuple[int, int], bytes], log2: int
) -> Dict[Tuple[int, int], Dict[Tuple[int, int], bytes]]:
    """Group tile payloads by block: {(block_x, block_y): {(local_x, local_y): payload}}.

    Which block a tile lands in, and where inside it, is decided here and
    nowhere else. `choose_block_log2` sizes candidate groupings and `pack`
    encodes the winning one; if those two disagreed by so much as a shift, the
    log2 that was measured as fitting would not be the one that gets written.
    """
    grouped: Dict[Tuple[int, int], Dict[Tuple[int, int], bytes]] = {}
    for (tile_x, tile_y), payload in encoded.items():
        block_x, block_y = tile_x >> log2, tile_y >> log2
        local = (tile_x - (block_x << log2), tile_y - (block_y << log2))
        grouped.setdefault((block_x, block_y), {})[local] = payload
    return grouped


#: Blocks below this size are worth merging: fewer resource ids, fewer loads.
SOFT_BLOCK_TARGET = 24000


def choose_block_log2(encoded: Dict[Tuple[int, int], bytes], budget: int,
                      soft_target: int = 0) -> int:
    """Pick tiles-per-block so we fit the resource budget without huge loads.

    A block is one jsonData resource and one load into RAM, so we want them
    big enough that the id count stays modest and small enough that loading
    one while panning does not blow the heap. log2 caps at 3 because the block
    directory stores at most 255 tiles (8x8 = 64 fits, 16x16 = 256 does not).
    """
    feasible: List[Tuple[int, int]] = []       # (log2, size of its largest block)
    for log2 in range(0, 4):
        blocks = group_into_blocks(encoded, log2)
        largest = max((block_size(tiles) for tiles in blocks.values()), default=0)
        if len(blocks) <= budget and largest <= MAX_BLOCK_BYTES:
            feasible.append((log2, largest))
    if not feasible:
        # Nothing fits: use the *smallest* grouping. It gives the smallest
        # blocks, which is the only direction that can help, and it leaves the
        # resource count for the size report to warn about. Returning the
        # largest grouping here used to guarantee a u16 offset overflow on
        # dense data -- a crash instead of a warning.
        return 0
    target = soft_target if soft_target > 0 else SOFT_BLOCK_TARGET
    roomy = [log2 for log2, largest in feasible if largest <= target]
    if roomy:
        return max(roomy)
    return min(log2 for log2, _largest in feasible)


def pack(ways, options: PackOptions) -> PackResult:
    data_zooms = sorted(set(options.data_zooms))
    ref_zoom = data_zooms[-1]
    features = build_features(ways, options, ref_zoom)
    bounds = clamp_bbox(features, ref_zoom)
    center = ((bounds[0] + bounds[2]) / 2.0, (bounds[1] + bounds[3]) / 2.0)

    blocks: Dict[Tuple[int, int, int], bytes] = {}
    block_log2: Dict[int, int] = {}
    tile_counts: Dict[int, int] = {}
    total_points = 0
    dropped_points = 0

    # Split the resource budget so the densest zoom gets the most ids.
    weights = {z: float(1 << (2 * (z - data_zooms[0]))) for z in data_zooms}
    weight_sum = sum(weights.values())

    for zoom in data_zooms:
        tiles, kept, dropped = build_tiles(features, zoom, ref_zoom, options)
        total_points += kept
        dropped_points += dropped
        tile_counts[zoom] = len(tiles)
        if not tiles:
            block_log2[zoom] = 3
            continue

        encoded = {key: encode_tile(feats) for key, feats in tiles.items()}
        budget = max(4, int(options.resource_budget * weights[zoom] / weight_sum))
        log2 = choose_block_log2(encoded, budget, options.block_target_bytes)
        block_log2[zoom] = log2

        for (block_x, block_y), tile_map in group_into_blocks(encoded, log2).items():
            # Size the block *before* encoding it. `encode_block` writes u16
            # payload offsets, so an oversized block raises on the way out and
            # never reaches a size check made after the fact.
            if block_size(tile_map) > MAX_BLOCK_BYTES:
                data = _shrink_block(zoom, log2, block_x, block_y, tile_map)
            else:
                data = encode_block(zoom, log2, block_x, block_y, tile_map)
            blocks[(zoom, block_x, block_y)] = data

    return PackResult(
        blocks=blocks,
        block_log2=block_log2,
        bounds=bounds,
        center=center,
        tile_counts=tile_counts,
        dropped_points=dropped_points,
        total_points=total_points,
    )


def _shrink_block(zoom, log2, block_x, block_y, tile_map) -> bytes:
    """Last-resort trim: drop the least important trailing layers per tile."""
    trimmed = dict(tile_map)
    for _ in range(6):
        # Measure without encoding, for the same reason as in `pack`.
        if block_size(trimmed) <= MAX_BLOCK_BYTES:
            return encode_block(zoom, log2, block_x, block_y, trimmed)
        for key, payload in list(trimmed.items()):
            trimmed[key] = _drop_last_layer(payload)
    if block_size(trimmed) > MAX_BLOCK_BYTES:
        raise ValueError(
            "block z%d %d/%d is %d bytes after dropping six layers per tile "
            "(max %d). The area is too dense at this zoom: drop the top zoom "
            "with ZOOMS=, raise SIMPLIFY=, or lower --max-points-per-tile."
            % (zoom, block_x, block_y, block_size(trimmed), MAX_BLOCK_BYTES))
    return encode_block(zoom, log2, block_x, block_y, trimmed)


def _drop_last_layer(payload: bytes) -> bytes:
    """Re-encode a tile payload without its highest-id (last drawn) layer."""
    layers = decode_tile(payload)
    if len(layers) <= 1:
        return payload
    layers = layers[:-1]
    feats: List[TileFeature] = []
    for layer_id, entries in layers:
        for geom_type, points in entries:
            feats.append(TileFeature(layer_id, geom_type, points, 0))
    return encode_tile(feats)
