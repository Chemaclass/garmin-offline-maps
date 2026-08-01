"""Downloadable city packs, and the catalogue the watch picks from.

A compiled-in pack lives in the `.prg` and can be megabytes. A *downloadable*
pack has to survive a much meaner set of limits, and those limits, not taste,
dictate the shape of everything here:

* `Application.Storage` holds **strings, not byte arrays**, so a block is
  base64 on the wire and in storage. That is 4 bytes stored per 3 bytes of map.
* A single stored value is capped at **8 KB** (the Core Topics figure; the API
  reference says 32 KB and the truth is device-dependent, so we plan for the
  smaller). A block must therefore stay under `MAX_BLOCK_BINARY` bytes so its
  base64 form fits.
* Total storage is about **128 KB**, which is the real ceiling on a city.
* BLE moves under 1 KB/s, so the whole download is a couple of minutes and
  wants to be resumable, one small request at a time.

Hence the layout, served as static files:

    catalogue.json          every city: slug, name, centre, size
    <slug>/meta.json        bounds, zooms, block origins, block keys
    <slug>/b<key>.json      one block, base64, one Storage value

The block bytes are the same MapPack blocks `emit.py` writes into resources.
Nothing about the byte format changes: `TileReader.mc` reads a downloaded block
and a compiled-in one with the same code.
"""

from __future__ import annotations

import base64
import json
import os
from typing import Dict, List, Sequence, Tuple

from .emit import KEY_MAX, KEY_SHIFT, block_origins
from .pack import FORMAT_VERSION, PackOptions, PackResult

#: Cap on one stored value. Conservative on purpose, see the module docstring.
MAX_STORAGE_VALUE = 8000

#: Binary bytes whose base64 still fits `MAX_STORAGE_VALUE`, with room for the
#: JSON quoting around it.
MAX_BLOCK_BINARY = (MAX_STORAGE_VALUE - 64) * 3 // 4

#: Total storage a city may occupy, base64 included.
STORAGE_BUDGET = 120 * 1024

#: What a downloadable pack is packed with.
#:
#: **A downloaded city is an orientation map, not a street map.** That is not a
#: tuning choice, it is what 128 KB buys. Measured against Berlin, the densest
#: city anyone is likely to ask for, at one data zoom:
#:
#:     simplify 2.0, 1100 pts -> 328 KB stored    (3x over budget)
#:     simplify 4.0,  300 pts -> 103 KB
#:     simplify 4.0,  260 pts ->  ~90 KB          <- this
#:     simplify 6.0,  200 pts ->  71 KB           (too sparse to read)
#:
#: Adding z16 takes the same city to 1.62 MB, so street-level detail can only
#: ever be compiled in. Within the budget the packer spends points on the
#: highest-priority layers first (see classify.py), so what survives is
#: motorways, primaries, secondaries, water, rail and parks. Residential
#: streets do not. Renders of this profile are in docs/PACKER.md.
DOWNLOAD_PROFILE = dict(
    data_zooms=(14,),
    min_display_zoom=13,
    max_display_zoom=15,
    simplify_px=4.0,
    max_points_per_tile=260,
    block_target_bytes=MAX_BLOCK_BINARY,
)


def download_options(name: str) -> PackOptions:
    """PackOptions for a city meant to be downloaded rather than compiled in."""
    return PackOptions(name=name, **DOWNLOAD_PROFILE)


def block_key(zoom_slot: int, block_x: int, block_y: int,
              origin_x: int, origin_y: int) -> int:
    """The same relative key `MapIndex.blockResource` computes on the watch."""
    rel_x, rel_y = block_x - origin_x, block_y - origin_y
    if rel_x < 0 or rel_y < 0 or rel_x > KEY_MAX or rel_y > KEY_MAX:
        raise ValueError("block %d/%d is outside the key range for this pack"
                         % (block_x, block_y))
    return (rel_x << KEY_SHIFT) | rel_y


class TooBig(Exception):
    """The city does not fit the watch's storage budget."""


def write_city(result: PackResult, options: PackOptions, slug: str,
               out_dir: str, attribution: str) -> Dict[str, object]:
    """Write `<out_dir>/<slug>/` and return its catalogue entry.

    Raises `TooBig` rather than writing something the watch will refuse
    halfway through downloading.
    """
    city_dir = os.path.join(out_dir, slug)
    os.makedirs(city_dir, exist_ok=True)

    data_zooms = sorted(set(options.data_zooms))
    origins = block_origins(result)

    oversize = [k for k, v in result.blocks.items() if len(v) > MAX_BLOCK_BINARY]
    if oversize:
        largest = max(len(result.blocks[k]) for k in oversize)
        raise TooBig(
            "%s: %d block(s) exceed the %d byte storage limit (largest %d). "
            "Lower --max-points-per-tile or raise --simplify."
            % (slug, len(oversize), MAX_BLOCK_BINARY, largest)
        )

    keys: List[int] = []
    total_stored = 0
    for (zoom, block_x, block_y), data in sorted(result.blocks.items()):
        slot = data_zooms.index(zoom)
        origin_x, origin_y = origins[zoom]
        key = block_key(slot, block_x, block_y, origin_x, origin_y)
        encoded = base64.b64encode(data).decode("ascii")
        path = os.path.join(city_dir, "b%d.json" % key)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump([encoded], fh, separators=(",", ":"))
        keys.append(key)
        total_stored += len(encoded)

    if total_stored > STORAGE_BUDGET:
        raise TooBig(
            "%s: %d KB of blocks exceeds the %d KB storage budget. "
            "Shrink the radius or raise --simplify."
            % (slug, total_stored // 1024, STORAGE_BUDGET // 1024)
        )

    west, south, east, north = result.bounds
    center_lon, center_lat = result.center
    meta = {
        "format": FORMAT_VERSION,
        "slug": slug,
        "name": options.name,
        "attribution": attribution,
        "dataZooms": data_zooms,
        "minZoom": options.min_display_zoom,
        "maxZoom": options.max_display_zoom,
        "blockLog2": [result.block_log2.get(z, 3) for z in data_zooms],
        "originX": [origins.get(z, (0, 0))[0] for z in data_zooms],
        "originY": [origins.get(z, (0, 0))[1] for z in data_zooms],
        "keyShift": KEY_SHIFT,
        "west": round(west, 7), "south": round(south, 7),
        "east": round(east, 7), "north": round(north, 7),
        "centerLon": round(center_lon, 7), "centerLat": round(center_lat, 7),
        "blocks": keys,
        "storedBytes": total_stored,
    }
    with open(os.path.join(city_dir, "meta.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, separators=(",", ":"), sort_keys=True)

    return {
        "slug": slug,
        "name": options.name,
        "lat": round(center_lat, 5),
        "lon": round(center_lon, 5),
        "blocks": len(keys),
        "storedBytes": total_stored,
    }


def write_catalogue(entries: Sequence[Dict[str, object]], out_dir: str,
                    base_url: str) -> str:
    """The index the settings page and the watch both read."""
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "catalogue.json")
    payload = {
        "format": FORMAT_VERSION,
        "baseUrl": base_url.rstrip("/"),
        "cities": sorted(entries, key=lambda c: c["name"]),
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=1, sort_keys=True)
        fh.write("\n")
    return path


def write_settings_xml(entries: Sequence[Dict[str, object]], path: str,
                       base_url: str) -> str:
    """Generate `resources/settings/settings.xml`.

    The city list is baked into the app rather than fetched, because Garmin
    Connect renders the settings page from the installed app: it cannot ask a
    server what the options are. Adding a city therefore means publishing the
    pack *and* shipping an app update, which is the trade for having a real
    picker instead of a free-text field.
    """
    lines = [
        '<!-- GENERATED by tools/mappack. Do not edit. -->',
        '<settings>',
        '    <setting propertyKey="@Properties.cityId" title="@Strings.SettingCity">',
        '        <settingConfig type="list">',
        '            <listEntry value="">@Strings.SettingCityBuiltIn</listEntry>',
    ]
    for city in sorted(entries, key=lambda c: c["name"]):
        lines.append('            <listEntry value="%s">%s</listEntry>'
                     % (city["slug"], _escape(str(city["name"]))))
    lines += [
        '        </settingConfig>',
        '    </setting>',
        '    <setting propertyKey="@Properties.packBaseUrl" title="@Strings.SettingBaseUrl">',
        '        <settingConfig type="alphaNumeric" maxLength="120" />',
        '    </setting>',
        '</settings>',
        '',
    ]
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return path


def write_properties_xml(path: str, base_url: str) -> str:
    lines = [
        '<!-- GENERATED by tools/mappack. Do not edit. -->',
        '<properties>',
        '    <property id="cityId" type="string"></property>',
        '    <property id="packBaseUrl" type="string">%s</property>' % _escape(base_url),
        '</properties>',
        '',
    ]
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return path


def _escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
