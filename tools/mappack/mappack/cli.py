"""Command line entry point:  python3 -m mappack --help"""

from __future__ import annotations

import argparse
import os
import sys
import time
from typing import List, Tuple

from . import geocode, osmread
from .emit import write_pack
from .pack import PackOptions, pack

DEFAULT_ATTRIBUTION = "(c) OpenStreetMap contributors"


def parse_bbox(text: str) -> Tuple[float, float, float, float]:
    parts = [p.strip() for p in text.replace(";", ",").split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("bbox needs 4 numbers: west,south,east,north")
    west, south, east, north = (float(p) for p in parts)
    if west >= east or south >= north:
        raise argparse.ArgumentTypeError("bbox must be west,south,east,north with west<east, south<north")
    return west, south, east, north


def parse_zooms(text: str) -> List[int]:
    zooms = sorted({int(p) for p in text.replace(" ", "").split(",") if p})
    if not zooms:
        raise argparse.ArgumentTypeError("--zooms needs at least one zoom level")
    for z in zooms:
        if not 4 <= z <= 18:
            raise argparse.ArgumentTypeError("zoom %d out of range (4..18)" % z)
    return zooms


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mappack",
        description="Build an offline vector map pack for the Garmin watch app.",
    )
    source = parser.add_argument_group("map source")
    source.add_argument("--input", help="OSM file (.osm, .osm.xml, .osm.bz2, .osm.gz, .osm.pbf)")
    source.add_argument("--city", help="place name to look up, e.g. \"Madrid\" -- packs "
                                       "--radius-km around its centre")
    source.add_argument("--bbox", type=parse_bbox,
                        help="west,south,east,north -- fetched live from Overpass when --input is absent")
    source.add_argument("--radius-km", type=float, default=geocode.DEFAULT_RADIUS_KM,
                        help="half-width of the box built around --city (default %.0f)"
                             % geocode.DEFAULT_RADIUS_KM)
    source.add_argument("--city-index", type=int, default=0,
                        help="which --city match to use when the name is ambiguous (default 0)")
    source.add_argument("--nominatim-url", default=geocode.DEFAULT_NOMINATIM_URL)
    source.add_argument("--overpass-url", default=osmread.DEFAULT_OVERPASS_URL)
    source.add_argument("--cache", help="cache the Overpass response at this path and reuse it")

    shape = parser.add_argument_group("pack shape")
    shape.add_argument("--name", default="map", help="pack name shown in the app")
    shape.add_argument("--zooms", type=parse_zooms, default=[12, 14, 16],
                       help="data zoom levels to store (default 12,14,16)")
    shape.add_argument("--min-zoom", type=int, default=None, help="lowest zoom the app allows")
    shape.add_argument("--max-zoom", type=int, default=None, help="highest zoom the app allows")
    shape.add_argument("--simplify", type=float, default=1.0,
                       help="Douglas-Peucker tolerance in screen pixels (default 1.0)")
    shape.add_argument("--max-points-per-tile", type=int, default=1100,
                       help="drawing budget per tile; lower = faster redraw (default 1100)")
    shape.add_argument("--buildings", action="store_true", help="include building footprints (large)")
    shape.add_argument("--resource-budget", type=int, default=200,
                       help="max number of jsonData resources (Connect IQ caps around 255)")
    shape.add_argument("--attribution", default=DEFAULT_ATTRIBUTION)

    out = parser.add_argument_group("output")
    out.add_argument("--out", default="mapdata/active", help="resource directory to write")
    out.add_argument("--index", default="source/generated/MapIndex.mc",
                     help="generated Monkey C index file")
    return parser


def resolve_city(args, parser, searcher=None) -> None:
    """Turn `--city NAME` into a bbox, and into `--name` when none was given.

    Mutates `args`, which is what the rest of `main` already reads. The
    candidate list is always printed: a name like "Springfield" has dozens of
    matches, and the packer picking one quietly is how you download the wrong
    continent.
    """
    if args.radius_km <= 0:
        parser.error("--radius-km must be positive")

    search = searcher if searcher is not None else geocode.search
    try:
        places = search(args.city, url=args.nominatim_url)
    except Exception as exc:                     # network, DNS, bad JSON, HTTP
        parser.error("could not look up %r: %s" % (args.city, exc))

    if not places:
        parser.error("no place called %r -- try adding a country, e.g. \"Murcia, Spain\""
                     % args.city)
    if not 0 <= args.city_index < len(places):
        parser.error("--city-index %d out of range (%d match%s)"
                     % (args.city_index, len(places), "" if len(places) == 1 else "es"))

    chosen = places[args.city_index]
    print("matches for %r:" % args.city, file=sys.stderr)
    for i, place in enumerate(places):
        print("  %s %d  %s" % ("->" if i == args.city_index else "  ", i, place.describe()),
              file=sys.stderr)
    if len(places) > 1 and args.city_index == 0:
        print("  (a different one? pass --city-index N)", file=sys.stderr)

    args.bbox = geocode.bbox_around(chosen.lat, chosen.lon, args.radius_km)
    west, south, east, north = args.bbox
    print("packing %.0f km around %.4f,%.4f -> %.4f,%.4f,%.4f,%.4f"
          % (args.radius_km * 2, chosen.lat, chosen.lon, west, south, east, north),
          file=sys.stderr)

    if args.name == "map":
        # The full display_name is "Madrid, Community of Madrid, Spain"; the app
        # shows this under a 390 px screen, so keep the first component.
        args.name = chosen.name.split(",")[0].strip() or args.city


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    # Exactly one of the three sets the region. Only --city with --bbox used to
    # be refused; --input silently beat both, so `--input x.osm --city Madrid`
    # packed the file and shipped it named "map" with nothing on stderr.
    given = [flag for flag, value in (("--input", args.input),
                                      ("--bbox", args.bbox),
                                      ("--city", args.city)) if value]
    if not given:
        parser.error("give --input FILE, --bbox west,south,east,north, or --city NAME")
    if len(given) > 1:
        parser.error("%s and %s each set the region; pass one"
                     % (", ".join(given[:-1]), given[-1]))
    if args.city:
        resolve_city(args, parser)

    zooms = args.zooms
    min_zoom = args.min_zoom if args.min_zoom is not None else max(1, zooms[0] - 1)
    max_zoom = args.max_zoom if args.max_zoom is not None else zooms[-1] + 1
    if min_zoom > zooms[0]:
        parser.error("--min-zoom must be <= the lowest data zoom")
    if max_zoom < zooms[-1]:
        parser.error("--max-zoom must be >= the highest data zoom")

    started = time.time()
    print("reading map data ...", file=sys.stderr)
    ways = osmread.load(args.input, args.bbox, args.overpass_url, args.cache)
    print("  %d ways" % len(ways), file=sys.stderr)

    options = PackOptions(
        data_zooms=zooms,
        min_display_zoom=min_zoom,
        max_display_zoom=max_zoom,
        simplify_px=args.simplify,
        max_points_per_tile=args.max_points_per_tile,
        include_buildings=args.buildings,
        resource_budget=args.resource_budget,
        name=args.name,
    )

    print("packing tiles ...", file=sys.stderr)
    result = pack(ways, options)
    manifest = write_pack(result, options, args.out, args.index, args.attribution)
    report(manifest, result, options, args, time.time() - started)
    return 0


def report(manifest, result, options, args, elapsed: float) -> None:
    west, south, east, north = result.bounds
    binary = manifest["binary_bytes"]
    base64_bytes = manifest["base64_bytes"]

    print("")
    print("  pack        %s" % manifest["name"])
    print("  bounds      %.5f,%.5f .. %.5f,%.5f" % (west, south, east, north))
    # From options, not re-derived from args: main already resolved the
    # defaults, and a second copy of that rule is a second thing to get wrong.
    print("  zoom data   %s   display %d..%d"
          % (", ".join("z%d" % z for z in manifest["data_zooms"]),
             options.min_display_zoom, options.max_display_zoom))
    print("")
    print("  %-6s %8s %10s %10s" % ("zoom", "tiles", "blocks", "block sz"))
    for zoom in manifest["data_zooms"]:
        blocks = [d for (z, _bx, _by), d in result.blocks.items() if z == zoom]
        size = "-" if not blocks else "2^%d" % result.block_log2.get(zoom, 3)
        print("  z%-5d %8d %10d %10s"
              % (zoom, result.tile_counts.get(zoom, 0), len(blocks), size))
    print("")
    print("  resources   %d jsonData ids (budget %d)"
          % (manifest["block_count"], options.resource_budget))
    print("  binary      %s" % human(binary))
    print("  in-app      %s  (base64, this is what lands in the .prg)" % human(base64_bytes))
    print("  points      %d kept, %d dropped by the per-tile budget"
          % (manifest["points_kept"], manifest["points_dropped"]))
    print("  took        %.1fs" % elapsed)
    print("")

    warn = []
    if manifest["block_count"] > 250:
        warn.append("over 250 jsonData resources -- Connect IQ caps resource ids near 255")
    if base64_bytes > 12 * 1024 * 1024:
        warn.append("over 12 MB in-app -- the Connect IQ store rejects .iq files above 15 MB")
    if manifest["points_dropped"] > manifest["points_kept"] * 0.25:
        warn.append("a lot of geometry was dropped -- raise --max-points-per-tile or add a zoom level")
    for message in warn:
        print("  WARNING: %s" % message, file=sys.stderr)
    if warn:
        print("", file=sys.stderr)

    print("  wrote %s and %s" % (os.path.join(args.out, "mapdata.xml"), args.index))


def human(n: int) -> str:
    if n < 1024:
        return "%d B" % n
    if n < 1024 * 1024:
        return "%.1f KB" % (n / 1024.0)
    return "%.2f MB" % (n / (1024.0 * 1024.0))


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
