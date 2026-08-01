"""Render a map pack to a PNG the way the watch would.

This is a deliberate re-implementation of `source/MapRenderer.mc` in Python: it
reads the *generated* `MapIndex.mc`, loads the *generated* jsonData block files,
and applies the same projection, the same tile lookup, the same two-pass draw
order and the same palette and pen widths, which it scrapes out of
`source/Palette.mc` so the two cannot drift.

That makes it two things at once:

  * a dev tool -- look at your pack before you spend ten minutes flashing it;
  * the closest thing to an integration test we can run without the Connect IQ
    SDK, because everything except Garmin's drawing primitives is exercised.

    python3 -m mappack.preview --pack ../../mapdata/active \\
        --index ../../source/generated/MapIndex.mc --zoom 15 --out preview.png
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import re
from typing import Dict, List, Optional, Tuple

from . import geom
from .decode import decode_block_header, decode_tile, decode_directory

TILE_SIZE = 256


class MapIndexFile:
    """The generated Monkey C index, read back into Python."""

    def __init__(self, path: str):
        with open(path, encoding="utf-8") as fh:
            source = fh.read()
        self.source = source
        self.extent = self._int("EXTENT")
        self.key_shift = self._int("KEY_SHIFT")
        self.min_zoom = self._int("MIN_ZOOM")
        self.max_zoom = self._int("MAX_ZOOM")
        self.pack_name = self._str("PACK_NAME")
        self.attribution = self._str("ATTRIBUTION")
        self.data_zooms = self._int_list("DATA_ZOOMS")
        self.block_log2 = self._int_list("BLOCK_LOG2")
        self.origin_x = self._int_list("BLOCK_ORIGIN_X")
        self.origin_y = self._int_list("BLOCK_ORIGIN_Y")
        self.center_lat = self._float("CENTER_LAT")
        self.center_lon = self._float("CENTER_LON")
        self.cases = self._cases()

    def _int(self, name: str) -> int:
        return int(re.search(r"\b%s = (-?\d+)" % name, self.source).group(1))

    def _float(self, name: str) -> float:
        return float(re.search(r"\b%s = (-?[\d.]+)d" % name, self.source).group(1))

    def _str(self, name: str) -> str:
        return re.search(r'\b%s = "([^"]*)"' % name, self.source).group(1)

    def _int_list(self, name: str) -> List[int]:
        body = re.search(r"\b%s = \[([^\]]*)\]" % name, self.source).group(1)
        return [int(v) for v in body.split(",") if v.strip()]

    def _cases(self) -> Dict[Tuple[int, int], str]:
        out: Dict[Tuple[int, int], str] = {}
        zoom = None
        for line in self.source.splitlines():
            match = re.search(r"\(z == (\d+)\) \{", line)
            if match:
                zoom = int(match.group(1))
            case = re.search(r"case (\d+): return Rez\.JsonData\.(\w+);", line)
            if case and zoom is not None:
                out[(zoom, int(case.group(1)))] = case.group(2)
        return out

    def zoom_slot(self, zoom: int) -> int:
        return self.data_zooms.index(zoom) if zoom in self.data_zooms else -1

    def data_zoom_for(self, display_zoom: int) -> int:
        best = self.data_zooms[0]
        for z in self.data_zooms:
            if z <= display_zoom:
                best = z
        return best

    def block_resource(self, zoom: int, block_x: int, block_y: int) -> Optional[str]:
        slot = self.zoom_slot(zoom)
        if slot < 0:
            return None
        rel_x = block_x - self.origin_x[slot]
        rel_y = block_y - self.origin_y[slot]
        if rel_x < 0 or rel_y < 0:
            return None
        limit = (1 << self.key_shift) - 1
        if rel_x > limit or rel_y > limit:
            return None
        return self.cases.get((zoom, (rel_x << self.key_shift) | rel_y))

    def block_log2_for(self, zoom: int) -> int:
        slot = self.zoom_slot(zoom)
        return self.block_log2[0] if slot < 0 else self.block_log2[slot]


class PackReader:
    """Loads block bytes out of the generated jsonData files."""

    def __init__(self, pack_dir: str, index: MapIndexFile):
        self.blocks_dir = os.path.join(pack_dir, "blocks")
        self.index = index
        self._cache: Dict[str, bytes] = {}

    def block(self, zoom: int, block_x: int, block_y: int) -> Optional[bytes]:
        name = self.index.block_resource(zoom, block_x, block_y)
        if name is None:
            return None
        if name not in self._cache:
            path = os.path.join(self.blocks_dir, name + ".json")
            if not os.path.exists(path):
                return None
            with open(path, encoding="utf-8") as fh:
                self._cache[name] = base64.b64decode(json.load(fh)[0])
        return self._cache[name]


class Style:
    """Colours and pen widths, scraped from source/Palette.mc."""

    def __init__(self, palette_mc: str, night: bool = True):
        with open(palette_mc, encoding="utf-8") as fh:
            source = fh.read()
        name = "NIGHT" if night else "DAY"
        self.colours = [int(v, 16) for v in
                        re.findall(r"0x([0-9A-Fa-f]{6})",
                                   re.search(r"const %s = \[(.*?)\];" % name, source,
                                             re.S).group(1))]
        self.width_far = self._ints(source, "WIDTH_FAR")
        self.width_near = self._ints(source, "WIDTH_NEAR")
        self.zoom_detail = int(re.search(r"ZOOM_DETAIL = (\d+)", source).group(1))
        self.background = self.colours[10]
        self.area_layers = 3  # layers 0..2 are filled

    @staticmethod
    def _ints(source: str, name: str) -> List[int]:
        body = re.search(r"const %s = \[([^\]]*)\]" % name, source).group(1)
        return [int(v) for v in body.split(",")]

    def rgb(self, index: int) -> Tuple[int, int, int]:
        value = self.colours[index]
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)

    def pen(self, layer: int, display_zoom: int) -> int:
        table = self.width_near if display_zoom >= self.zoom_detail else self.width_far
        return table[layer] if 0 <= layer < len(table) else 1


def render(pack_dir: str, index_path: str, palette_mc: str, size: int = 454,
           zoom: Optional[int] = None, lat: Optional[float] = None,
           lon: Optional[float] = None, heading: float = 0.0,
           night: bool = True):
    from PIL import Image, ImageDraw

    index = MapIndexFile(index_path)
    reader = PackReader(pack_dir, index)
    style = Style(palette_mc, night)

    display_zoom = zoom if zoom is not None else index.data_zooms[-1]
    centre_lat = lat if lat is not None else index.center_lat
    centre_lon = lon if lon is not None else index.center_lon

    image = Image.new("RGB", (size, size), style.rgb(10))
    draw = ImageDraw.Draw(image)

    data_zoom = index.data_zoom_for(display_zoom)
    scale = 2.0 ** (display_zoom - data_zoom)
    log2 = index.block_log2_for(data_zoom)

    half = size / 2.0
    centre_x = geom.lon_to_world_x(centre_lon, data_zoom)
    centre_y = geom.lat_to_world_y(centre_lat, data_zoom)
    radius = math.hypot(half, half) / scale

    min_tx = math.floor((centre_x - radius) / TILE_SIZE)
    max_tx = math.floor((centre_x + radius) / TILE_SIZE)
    min_ty = math.floor((centre_y - radius) / TILE_SIZE)
    max_ty = math.floor((centre_y + radius) / TILE_SIZE)

    cos_t, sin_t = math.cos(heading), math.sin(heading)
    rotated = heading != 0.0
    units_to_pixels = scale * TILE_SIZE / index.extent

    stats = {"tiles": 0, "segments": 0, "missing": 0}

    def to_screen(origin_x, origin_y, x, y):
        ux = origin_x + x * units_to_pixels
        uy = origin_y + y * units_to_pixels
        if rotated:
            return (half + ux * cos_t + uy * sin_t, half - ux * sin_t + uy * cos_t)
        return (half + ux, half + uy)

    for pass_index in (0, 1):
        for tile_y in range(min_ty, max_ty + 1):
            for tile_x in range(min_tx, max_tx + 1):
                block = reader.block(data_zoom, tile_x >> log2, tile_y >> log2)
                if block is None:
                    if pass_index == 0:
                        stats["missing"] += 1
                    continue
                local = (tile_x - ((tile_x >> log2) << log2),
                         tile_y - ((tile_y >> log2) << log2))
                offset = decode_directory(block).get(local)
                if offset is None:
                    continue
                if pass_index == 0:
                    stats["tiles"] += 1

                origin_x = (tile_x * TILE_SIZE - centre_x) * scale
                origin_y = (tile_y * TILE_SIZE - centre_y) * scale

                for layer_id, features in decode_tile(block, offset):
                    is_area = layer_id < style.area_layers
                    if (pass_index == 0) != is_area:
                        continue
                    colour = style.rgb(layer_id)
                    width = style.pen(layer_id, display_zoom)
                    for geom_type, points in features:
                        screen = [to_screen(origin_x, origin_y, x, y) for x, y in points]
                        if geom_type == 1 and len(screen) >= 3:
                            draw.polygon(screen, fill=colour)
                            stats["segments"] += len(screen)
                        elif len(screen) >= 2:
                            draw.line(screen, fill=colour, width=width, joint="curve")
                            stats["segments"] += len(screen) - 1

    _draw_chrome(draw, size, style, display_zoom, centre_lat, index)
    return image, stats


def _draw_chrome(draw, size, style, display_zoom, centre_lat, index):
    """The bits of the overlay that are worth eyeballing: scale bar + marker."""
    half = size // 2
    draw.ellipse([half - 9, half - 9, half + 9, half + 9], fill=style.rgb(11))
    draw.ellipse([half - 6, half - 6, half + 6, half + 6], fill=style.rgb(13))

    mpp = geom.meters_per_pixel(centre_lat, display_zoom)
    target = size * 0.28
    steps = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000]
    metres = next((s for s in steps if s >= mpp * target), steps[-1])
    pixels = int(metres / mpp)
    if 8 < pixels < size:
        y = int(size * 0.855)
        x = (size - pixels) // 2
        ink = style.rgb(11)
        draw.line([(x, y), (x + pixels, y)], fill=ink, width=2)
        draw.line([(x, y - 4), (x, y + 4)], fill=ink, width=2)
        draw.line([(x + pixels, y - 4), (x + pixels, y + 4)], fill=ink, width=2)
        label = "%d km" % (metres // 1000) if metres >= 1000 else "%d m" % metres
        draw.text((half - 14, y + 6), label, fill=ink)


def main(argv=None) -> int:
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    root = os.path.dirname(here)

    parser = argparse.ArgumentParser(prog="mappack.preview",
                                     description="Render a map pack to PNG as the watch would.")
    parser.add_argument("--pack", default=os.path.join(root, "mapdata", "active"))
    parser.add_argument("--index", default=os.path.join(root, "source", "generated", "MapIndex.mc"))
    parser.add_argument("--palette", default=os.path.join(root, "source", "Palette.mc"))
    parser.add_argument("--size", type=int, default=454, help="454 = Venu 3, 390 = Venu 3S")
    parser.add_argument("--zoom", type=int, default=None)
    parser.add_argument("--lat", type=float, default=None)
    parser.add_argument("--lon", type=float, default=None)
    parser.add_argument("--heading", type=float, default=0.0, help="degrees, for heading-up mode")
    parser.add_argument("--day", action="store_true", help="use the light palette")
    parser.add_argument("--out", default="preview.png")
    args = parser.parse_args(argv)

    image, stats = render(args.pack, args.index, args.palette, args.size, args.zoom,
                          args.lat, args.lon, math.radians(args.heading), not args.day)
    image.save(args.out)
    print("%s  z%s  %d tiles, %d segments, %d blocks missing"
          % (args.out, args.zoom, stats["tiles"], stats["segments"], stats["missing"]))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
