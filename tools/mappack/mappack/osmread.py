"""Read OSM data into a flat list of tagged ways.

Supported inputs:
  * ``.osm`` / ``.xml`` / ``.osm.xml``  -- OSM XML (what Overpass returns)
  * ``.osm.bz2`` / ``.osm.gz``          -- the same, compressed
  * ``.osm.pbf``                        -- only if ``osmium`` (pyosmium) is installed
  * Overpass API                        -- fetched live for a bounding box
"""

from __future__ import annotations

import bz2
import gzip
import os
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from .classify import build_overpass_query
# (lon, lat) degrees here, world pixels once `geom.project` has run. Same pair
# either way, and these coordinates go straight into it, so the alias is geom's.
from .geom import BBox, Point

DEFAULT_OVERPASS_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "garmin-offline-maps mappack (+https://github.com/Chemaclass/garmin-offline-maps)"

#: What the licence asks a map built from this data to say, and so what both
#: entry points default to. It lives beside the source it credits: a pack and a
#: published city are the same data and must not credit it differently.
DEFAULT_ATTRIBUTION = "(c) OpenStreetMap contributors"


@dataclass
class Way:
    tags: Dict[str, str]
    coords: List[Point] = field(default_factory=list)
    closed: bool = False


def _open(path: str):
    if path.endswith(".bz2"):
        return bz2.open(path, "rb")
    if path.endswith(".gz"):
        return gzip.open(path, "rb")
    return open(path, "rb")


def read_osm_xml(stream) -> List[Way]:
    """Stream-parse OSM XML. Nodes are kept only while ways still need them."""
    nodes: Dict[int, Point] = {}
    ways: List[Way] = []
    # relation id -> list of outer way member ids
    pending_relations: List[Tuple[Dict[str, str], List[int]]] = []
    way_by_id: Dict[int, Way] = {}

    cur_way_nodes: Optional[List[int]] = None
    cur_tags: Optional[Dict[str, str]] = None
    cur_id: Optional[int] = None
    cur_rel_members: Optional[List[int]] = None
    raw_ways: List[Tuple[int, Dict[str, str], List[int]]] = []

    for event, elem in ET.iterparse(stream, events=("start", "end")):
        tag = elem.tag
        if event == "start":
            if tag == "node":
                pass
            elif tag == "way":
                cur_way_nodes = []
                cur_tags = {}
                cur_id = int(elem.get("id", "0"))
            elif tag == "relation":
                cur_rel_members = []
                cur_tags = {}
            elif tag == "nd" and cur_way_nodes is not None:
                cur_way_nodes.append(int(elem.get("ref")))
            elif tag == "member" and cur_rel_members is not None:
                if elem.get("type") == "way" and elem.get("role") in ("outer", "", None):
                    cur_rel_members.append(int(elem.get("ref")))
            elif tag == "tag" and cur_tags is not None:
                cur_tags[elem.get("k")] = elem.get("v")
            continue

        # event == "end"
        if tag == "node":
            try:
                nodes[int(elem.get("id"))] = (float(elem.get("lon")), float(elem.get("lat")))
            except (TypeError, ValueError):
                pass
            elem.clear()
        elif tag == "way":
            raw_ways.append((cur_id or 0, cur_tags or {}, cur_way_nodes or []))
            cur_way_nodes = None
            cur_tags = None
            cur_id = None
            elem.clear()
        elif tag == "relation":
            if cur_tags and cur_rel_members:
                pending_relations.append((cur_tags, cur_rel_members))
            cur_rel_members = None
            cur_tags = None
            elem.clear()

    for way_id, tags, refs in raw_ways:
        coords = [nodes[r] for r in refs if r in nodes]
        if len(coords) < 2:
            continue
        way = Way(tags=tags, coords=coords, closed=(len(refs) > 2 and refs[0] == refs[-1]))
        way_by_id[way_id] = way
        if tags:
            ways.append(way)

    # Multipolygon relations: emit each outer member as its own polygon and
    # inherit the relation's tags. Holes are ignored on purpose -- at watch
    # scale an unfilled lake island is not worth the bytes.
    for tags, members in pending_relations:
        for member_id in members:
            member = way_by_id.get(member_id)
            if member is None or len(member.coords) < 3:
                continue
            ways.append(Way(tags=dict(tags), coords=list(member.coords), closed=True))

    return ways


def read_pbf(path: str) -> List[Way]:
    try:
        import osmium  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on optional dep
        raise SystemExit(
            "Reading .osm.pbf needs pyosmium:  pip install osmium\n"
            "Or convert first:  osmium cat region.osm.pbf -o region.osm.bz2"
        ) from exc

    ways: List[Way] = []

    class Handler(osmium.SimpleHandler):  # pragma: no cover - optional dep
        def way(self, w):
            tags = {t.k: t.v for t in w.tags}
            if not tags:
                return
            try:
                coords = [(n.lon, n.lat) for n in w.nodes if n.location.valid()]
            except osmium.InvalidLocationError:
                return
            if len(coords) < 2:
                return
            ways.append(Way(tags=tags, coords=coords, closed=w.is_closed()))

    Handler().apply_file(path, locations=True)
    return ways


def fetch_overpass(bbox: BBox, url: str = DEFAULT_OVERPASS_URL,
                   cache_path: Optional[str] = None, timeout: int = 300) -> List[Way]:
    """bbox is (min_lon, min_lat, max_lon, max_lat)."""
    import urllib.request

    if cache_path and os.path.exists(cache_path):
        print("  using cached Overpass response: %s" % cache_path, file=sys.stderr)
        with _open(cache_path) as fh:
            return read_osm_xml(fh)

    min_lon, min_lat, max_lon, max_lat = bbox
    query = build_overpass_query(min_lat, min_lon, max_lat, max_lon)
    print("  querying Overpass (%s) ..." % url, file=sys.stderr)
    request = urllib.request.Request(
        url,
        data=query.encode("utf-8"),
        headers={"User-Agent": USER_AGENT, "Content-Type": "text/plain; charset=utf-8"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = response.read()
    if cache_path:
        os.makedirs(os.path.dirname(os.path.abspath(cache_path)) or ".", exist_ok=True)
        with open(cache_path, "wb") as fh:
            fh.write(payload)
        print("  cached %.1f KB to %s" % (len(payload) / 1024.0, cache_path), file=sys.stderr)

    import io

    return read_osm_xml(io.BytesIO(payload))


def load(path: Optional[str], bbox: Optional[BBox] = None,
         overpass_url: str = DEFAULT_OVERPASS_URL,
         cache_path: Optional[str] = None) -> List[Way]:
    if path:
        if path.endswith(".pbf"):
            return read_pbf(path)
        with _open(path) as fh:
            return read_osm_xml(fh)
    if bbox is None:
        raise SystemExit("Need either --input or --bbox")
    return fetch_overpass(bbox, overpass_url, cache_path)
