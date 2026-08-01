# The MapPack binary format

A MapPack is a set of vector tiles compiled into a Connect IQ app as
`jsonData` resources. This document is the contract between three
implementations that must agree byte for byte:

| Implementation | File | Role |
|---|---|---|
| Writer | `tools/mappack/mappack/pack.py` | produces blocks |
| Reference reader | `tools/mappack/mappack/decode.py` | used by the tests |
| On-watch reader | `source/TileReader.mc` | used by the app |

`tests/test_format.py` round-trips the writer against the reference reader;
`tests/test_preview.py` drives the reference reader over the real generated
resources. Change one implementation and you must change all three.

## Why not just use Mapbox Vector Tiles?

MVT is protobuf, and there is no protobuf decoder on Connect IQ — writing one
in Monkey C would cost more heap and more interpreted calls than the map data
itself. This format keeps MVT's good ideas (tile-local coordinates, delta and
zigzag encoding, layers) and drops everything that costs bytes or cycles on a
768 KB device: no tags, no keys, no strings, no feature ids, no wire types.

## Transport

Each block is written as a JSON file containing a one-element array holding
base64:

```json
["TQEQAwB..."]
```

A one-element array rather than a bare string, so the top-level JSON value is
unambiguously a container. On the watch:

```monkeyc
var payload = Application.loadResource(Rez.JsonData.b16_4011_3088);
var bytes = StringUtil.convertEncodedString(payload[0], {
    :fromRepresentation => StringUtil.REPRESENTATION_STRING_BASE64,
    :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY
});
```

Base64 costs 33% on disk. That is the price of there being no binary resource
type in Connect IQ; it is still far cheaper than a JSON array of numbers, which
would cost roughly 8–16 bytes of heap per coordinate once parsed.

## Coordinates

Every tile is 256 world pixels square at its zoom, and geometry inside it is
quantised to an **extent of 1024** units per axis — four units per pixel, so
about 40 cm at z16 in mid-latitudes. Geometry is clipped to the tile with a
**64-unit buffer** (16 px), so coordinates legitimately run from −64 to 1088;
the buffer is what stops a road stroke ending abruptly at a tile seam.

Converting a tile-local coordinate back to a world pixel:

```
worldX = tileX * 256 + localX * 256 / EXTENT
```

## Block layout

All integers little-endian. Offsets are from the start of the block.

```
u8   magic        0x4D ('M')
u8   version      1
u8   zoom         data zoom of every tile in this block
u8   blockLog2    the block covers 2^blockLog2 tiles per axis
u16  blockX       tileX >> blockLog2
u16  blockY       tileY >> blockLog2
u8   tileCount    non-empty tiles, 1..255

tileCount x directory entry (4 bytes):
  u8   localX     0 .. 2^blockLog2 - 1
  u8   localY
  u16  offset     byte offset of this tile's payload

... tile payloads, in directory order ...
```

Empty tiles are simply absent from the directory, which is why open water and
farmland cost nothing.

Offsets are `u16`, so a block must stay under 64 KB; the packer enforces a
60 KB ceiling and, if a block would still be too big, drops its least important
layer rather than emitting something unreadable.

`blockLog2` is chosen per zoom by the packer, balancing two pressures: Connect
IQ runs out of resource ids near 255, so blocks must not be too small; and each
block is one heap allocation on load, so they must not be too big. It picks the
largest block size that keeps every block under 24 KB while fitting the id
budget, capped at 8×8 (64 tiles) because the directory count is a `u8`.

## Tile payload

```
u8   layerCount

layerCount x layer:
  u8   layerId       ascending, and ascending == draw order
  u16  layerBytes    size of everything after this field
  u8   featureCount  1..255

  featureCount x feature:
    u8       geomType     0 = polyline, 1 = polygon
    uvarint  pointCount
    pointCount x (svarint dx, svarint dy)
```

`layerBytes` exists so the renderer can skip a layer without walking its
varints. That is what makes the two-pass draw affordable: pass one draws the
filled areas of every visible tile, pass two draws the strokes. Without it, a
lake in one tile would paint over a road in the tile next door.

The first point's deltas are relative to `(0, 0)`, so the sequence is uniform —
no special case for the first coordinate.

### Varints

`uvarint` is LEB128: seven payload bits per byte, high bit set means another
byte follows.

`svarint` is a `uvarint` of the zigzag-mapped value:

```
encode:  (n << 1) ^ (n >> 31)      // arithmetic shift, so -1 for negatives
decode:  (v >> 1) ^ -(v & 1)
```

Zigzag keeps small negative deltas one byte wide, which matters because after
Douglas–Peucker most consecutive points are within ±63 units of each other.

## Layers

Layer ids are also the draw order, low first. They are defined once in
`tools/mappack/mappack/classify.py` and mirrored in `source/Palette.mc`; a test
asserts the two agree.

| id | Layer | Geometry | Typical minimum zoom |
|---|---|---|---|
| 0 | water areas | polygon | 9 |
| 1 | parks, forest, grass | polygon | 12 |
| 2 | buildings | polygon | 16 (opt-in) |
| 3 | rivers, streams | line | 11 / 15 |
| 4 | railways | line | 12 |
| 5 | paths, footways, tracks | line | 14 / 15 |
| 6 | residential, unclassified, service | line | 13 / 16 |
| 7 | secondary, tertiary | line | 11 / 12 |
| 8 | primary | line | 10 |
| 9 | motorway, trunk | line | 9 |

Polygons are stored without their closing point — the renderer closes them —
and holes are dropped. On a 1.4" screen an unfilled island in a lake is not
worth the bytes.

## The generated index

`tools/mappack` also writes `source/generated/MapIndex.mc`, which is the only
way the app can turn a tile coordinate into a resource, since `Rez` symbols are
resolved at compile time. It holds the pack's bounds, the data zooms, the block
size per zoom, and a switch:

```monkeyc
function blockResource(z, blockX, blockY) {
    var slot = zoomSlot(z);
    if (slot < 0) { return null; }
    var rx = blockX - BLOCK_ORIGIN_X[slot];
    var ry = blockY - BLOCK_ORIGIN_Y[slot];
    if (rx < 0 || ry < 0 || rx > 1023 || ry > 1023) { return null; }
    var key = (rx << KEY_SHIFT) | ry;
    if (z == 16) {
        switch (key) {
            case 0: return Rez.JsonData.b16_4011_3088;
            ...
        }
    }
    return null;
}
```

Block indices are stored **relative to the pack's origin** per zoom. Absolute
tile indices reach 65535 at z16, which would not fit two axes into one 31-bit
switch key; relative ones stay under 1024. A switch rather than a Dictionary
because a switch costs no heap at runtime.

## Version history

| Version | Change |
|---|---|
| 1 | Initial format |
