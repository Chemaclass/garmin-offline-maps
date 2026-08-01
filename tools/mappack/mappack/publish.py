"""Build the downloadable city catalogue:  python3 -m mappack.publish --help

Takes a list of city names, geocodes each one, packs it at the download
profile, and writes a static site the watch can fetch from. GitHub Pages serves
it as-is; there is no server to run.

    python3 -m mappack.publish --cities cities.txt --out ../../site \\
        --base-url https://chemaclass.github.io/garmin-offline-maps

Cities that do not fit the watch's storage budget are reported and skipped
rather than silently truncated, because a half-downloaded city is worse than an
absent one.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from typing import List, Optional

from . import citypack, geocode, osmread
from .pack import pack

DEFAULT_BASE_URL = "https://chemaclass.github.io/garmin-offline-maps/packs"
DEFAULT_ATTRIBUTION = "(c) OpenStreetMap contributors"

#: Nominatim asks for no more than one request a second.
GEOCODE_INTERVAL = 1.1


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "city"


def read_city_list(path: str) -> List[str]:
    names = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line:
                names.append(line)
    return names


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mappack.publish",
        description="Pack a list of cities into a downloadable catalogue.",
    )
    parser.add_argument("--cities", help="file with one city name per line")
    parser.add_argument("--city", action="append", default=[],
                        help="a single city; repeatable")
    parser.add_argument("--out", default="site", help="directory to write")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--radius-km", type=float, default=geocode.DEFAULT_RADIUS_KM)
    parser.add_argument("--attribution", default=DEFAULT_ATTRIBUTION)
    parser.add_argument("--settings", help="also write this settings.xml")
    parser.add_argument("--properties", help="also write this properties.xml")
    parser.add_argument("--cache-dir", help="reuse Overpass responses from here")
    parser.add_argument("--overpass-url", default=osmread.DEFAULT_OVERPASS_URL)
    return parser


def build_city(name: str, args, searcher=None, loader=None) -> Optional[dict]:
    """Geocode, fetch, pack and write one city. None when it did not fit."""
    search = searcher if searcher is not None else geocode.search
    places = search(name, url=geocode.DEFAULT_NOMINATIM_URL)
    if not places:
        print("  no match for %r, skipped" % name, file=sys.stderr)
        return None
    place = places[0]
    slug = slugify(name)
    bbox = geocode.bbox_around(place.lat, place.lon, args.radius_km)

    cache = None
    if args.cache_dir:
        os.makedirs(args.cache_dir, exist_ok=True)
        cache = os.path.join(args.cache_dir, slug + ".osm")

    load = loader if loader is not None else osmread.load
    ways = load(None, bbox, args.overpass_url, cache)

    options = citypack.download_options(place.name.split(",")[0].strip() or name)
    result = pack(ways, options)
    try:
        entry = citypack.write_city(result, options, slug, args.out, args.attribution)
    except citypack.TooBig as exc:
        print("  %s" % exc, file=sys.stderr)
        return None
    print("  %-22s %2d blocks  %5.1f KB"
          % (entry["name"], entry["blocks"], entry["storedBytes"] / 1024.0),
          file=sys.stderr)
    return entry


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    names = list(args.city)
    if args.cities:
        names += read_city_list(args.cities)
    if not names:
        parser.error("give --city NAME (repeatable) or --cities FILE")

    entries = []
    for i, name in enumerate(names):
        print("packing %s ..." % name, file=sys.stderr)
        if i:
            time.sleep(GEOCODE_INTERVAL)
        entry = build_city(name, args)
        if entry is not None:
            entries.append(entry)

    if not entries:
        print("nothing packed", file=sys.stderr)
        return 1

    path = citypack.write_catalogue(entries, args.out, args.base_url)
    print("\nwrote %s with %d cities" % (path, len(entries)))
    if args.settings:
        print("wrote %s" % citypack.write_settings_xml(entries, args.settings,
                                                       args.base_url))
    if args.properties:
        print("wrote %s" % citypack.write_properties_xml(args.properties,
                                                         args.base_url))
    total = sum(int(e["storedBytes"]) for e in entries)
    print("largest city %.1f KB, catalogue total %.1f KB"
          % (max(int(e["storedBytes"]) for e in entries) / 1024.0, total / 1024.0))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
