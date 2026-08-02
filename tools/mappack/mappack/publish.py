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
import urllib.error
from typing import List, Optional

from . import citypack, geocode, osmread
from .osmread import Way
from .pack import pack

DEFAULT_BASE_URL = "https://chemaclass.github.io/garmin-offline-maps/packs"
DEFAULT_ATTRIBUTION = "(c) OpenStreetMap contributors"

#: Nominatim asks for no more than one request a second.
GEOCODE_INTERVAL = 1.1

#: Overpass is a shared free service and will hand out 429s to a batch that
#: hammers it. Pace the fetches and back off when it complains: a rate limit is
#: a request to wait, not an error to give up on.
#: https://dev.overpass-api.de/overpass-doc/en/preface/commons.html
OVERPASS_INTERVAL = 8.0
OVERPASS_RETRIES = 4
OVERPASS_BACKOFF = 20.0

#: Half-width of a published city, in km. See --radius-km.
PUBLISH_RADIUS_KM = 5.0


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "city"


def read_city_list(path: str) -> List[str]:
    """One city per line. `Query | slug` overrides the generated slug.

    The override exists because a name often needs qualifying to geocode
    correctly ("Valencia, Spain") while the slug people type should not carry
    the qualifier. Without it that city publishes as `valencia-spain` and
    anyone typing `valencia` gets nothing, which is the same silent 404 that
    capital letters used to cause.
    """
    names = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line:
                names.append(line)
    return names


def split_entry(entry: str):
    """`"Valencia, Spain | valencia"` -> `("Valencia, Spain", "valencia")`."""
    if "|" in entry:
        query, slug = entry.split("|", 1)
        return query.strip(), slugify(slug.strip())
    return entry.strip(), None


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
    # 5 km rather than the geocoder default of 6: Berlin is 71 KB at 5 km
    # and 110 KB at 6, and the watch has about 128 KB in total.
    parser.add_argument("--radius-km", type=float, default=PUBLISH_RADIUS_KM)
    parser.add_argument("--attribution", default=DEFAULT_ATTRIBUTION)
    parser.add_argument("--settings", help="also write this settings.xml")
    parser.add_argument("--properties", help="also write this properties.xml")
    parser.add_argument("--cache-dir", help="reuse Overpass responses from here")
    parser.add_argument("--overpass-url", default=osmread.DEFAULT_OVERPASS_URL)
    return parser


def build_city(entry: str, args, searcher=None, loader=None) -> Optional[dict]:
    """Geocode, fetch, pack and write one city. None when it did not fit."""
    name, override = split_entry(entry)
    search = searcher if searcher is not None else geocode.search
    places = search(name, url=geocode.DEFAULT_NOMINATIM_URL)
    if not places:
        print("  no match for %r, skipped" % name, file=sys.stderr)
        return None
    place = places[0]
    slug = override if override else slugify(name)
    bbox = geocode.bbox_around(place.lat, place.lon, args.radius_km)

    cache = None
    if args.cache_dir:
        os.makedirs(args.cache_dir, exist_ok=True)
        cache = os.path.join(args.cache_dir, slug + ".osm")

    load = loader if loader is not None else osmread.load
    ways = crop(load_with_retry(load, bbox, args, cache), bbox)

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


def crop(ways, bbox):
    """Keep only the geometry inside `bbox`.

    Overpass returns whole ways that merely touch the query box, and a cached
    response was fetched for whatever radius was in force that day. Cropping
    here makes `--radius-km` mean the same thing on a cache hit as on a fresh
    fetch, which is what stops a re-run quietly producing a bigger pack.
    """
    west, south, east, north = bbox
    out = []
    for way in ways:
        inside = [p for p in way.coords
                  if west <= p[0] <= east and south <= p[1] <= north]
        if len(inside) >= 2:
            out.append(Way(tags=way.tags, coords=inside, closed=way.closed))
    return out


def load_with_retry(load, bbox, args, cache):
    """Fetch from Overpass, waiting out a rate limit rather than dying on it."""
    delay = OVERPASS_BACKOFF
    for attempt in range(OVERPASS_RETRIES):
        try:
            return load(None, bbox, args.overpass_url, cache)
        except urllib.error.HTTPError as exc:
            retryable = exc.code in (429, 502, 503, 504)
            if not retryable or attempt == OVERPASS_RETRIES - 1:
                raise
            print("  Overpass returned %d, waiting %.0fs" % (exc.code, delay),
                  file=sys.stderr)
            time.sleep(delay)
            delay *= 2
    return None


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    names = list(args.city)
    if args.cities:
        names += read_city_list(args.cities)
    if not names:
        parser.error("give --city NAME (repeatable) or --cities FILE")

    built = 0
    for i, name in enumerate(names):
        print("packing %s ..." % name, file=sys.stderr)
        if i:
            time.sleep(max(GEOCODE_INTERVAL, OVERPASS_INTERVAL))
        try:
            if build_city(name, args) is not None:
                built += 1
        except Exception as exc:
            # One city failing must not discard the ones already fetched:
            # Overpass minutes are expensive and a batch is long.
            print("  %s failed: %s" % (name, exc), file=sys.stderr)

    # The catalogue lists what is published, not what this run managed to
    # build, so an interrupted batch still leaves earlier cities discoverable.
    entries = citypack.scan_published(args.out)
    if not entries:
        print("nothing published", file=sys.stderr)
        return 1
    print("\nbuilt %d this run, %d published in total" % (built, len(entries)),
          file=sys.stderr)

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
