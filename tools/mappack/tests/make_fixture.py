#!/usr/bin/env python3
"""Generate the synthetic OSM fixture used by the tests and the demo pack.

The geometry is invented -- a tidy grid town with a river, a lake, a park, a
rail line and a motorway -- but it sits at real Berlin coordinates so you can
stand in the city, open the app, and watch follow-me put the marker on the
map. The streets are not Berlin's; only the location is.

    python3 tests/make_fixture.py tests/demo-city.osm

Moving this somewhere else means regenerating the fixture *and* the committed
demo pack (`make demo`), and updating the bounds assertions in
tests/integration/test_pack.py.
"""

from __future__ import annotations

import math
import sys
from typing import Dict, List, Tuple

CENTER_LON = 13.3632
CENTER_LAT = 52.5122

# Roughly 4.4 km x 3.3 km. A degree of longitude is shorter this far north, so
# HALF_W is wider than it would be nearer the equator to keep the same span on
# the ground: 0.026 / cos(52.5) * cos(40.4) is where this number comes from.
HALF_W = 0.0325
HALF_H = 0.015

GRID_COLS = 17
GRID_ROWS = 13


class Builder:
    def __init__(self) -> None:
        self.nodes: List[Tuple[int, float, float]] = []
        self.ways: List[Tuple[int, List[int], Dict[str, str]]] = []
        self._node_id = 1
        self._way_id = 1

    def node(self, lon: float, lat: float) -> int:
        nid = self._node_id
        self._node_id += 1
        self.nodes.append((nid, lon, lat))
        return nid

    def way(self, points: List[Tuple[float, float]], tags: Dict[str, str],
            closed: bool = False) -> int:
        refs = [self.node(lon, lat) for lon, lat in points]
        if closed:
            refs.append(refs[0])
        wid = self._way_id
        self._way_id += 1
        self.ways.append((wid, refs, tags))
        return wid

    def dump(self) -> str:
        out = ['<?xml version="1.0" encoding="UTF-8"?>',
               '<osm version="0.6" generator="mappack test fixture">']
        lons = [n[1] for n in self.nodes]
        lats = [n[2] for n in self.nodes]
        out.append('  <bounds minlat="%.7f" minlon="%.7f" maxlat="%.7f" maxlon="%.7f"/>'
                   % (min(lats), min(lons), max(lats), max(lons)))
        for nid, lon, lat in self.nodes:
            out.append('  <node id="%d" lon="%.7f" lat="%.7f" version="1"/>' % (nid, lon, lat))
        for wid, refs, tags in self.ways:
            out.append('  <way id="%d" version="1">' % wid)
            for ref in refs:
                out.append('    <nd ref="%d"/>' % ref)
            for key, value in sorted(tags.items()):
                out.append('    <tag k="%s" v="%s"/>' % (key, value))
            out.append('  </way>')
        out.append('</osm>')
        out.append('')
        return "\n".join(out)


def build() -> Builder:
    b = Builder()
    west, east = CENTER_LON - HALF_W, CENTER_LON + HALF_W
    south, north = CENTER_LAT - HALF_H, CENTER_LAT + HALF_H

    # --- grid of residential streets -------------------------------------
    for col in range(GRID_COLS):
        lon = west + (east - west) * col / (GRID_COLS - 1)
        pts = []
        for step in range(9):
            lat = south + (north - south) * step / 8.0
            # a gentle wobble so simplification has something to chew on
            pts.append((lon + math.sin(step * 0.9 + col) * 0.00018, lat))
        b.way(pts, {"highway": "residential", "name": "Calle %d" % (col + 1)})

    for row in range(GRID_ROWS):
        lat = south + (north - south) * row / (GRID_ROWS - 1)
        pts = []
        for step in range(11):
            lon = west + (east - west) * step / 10.0
            pts.append((lon, lat + math.cos(step * 0.7 + row) * 0.00012))
        b.way(pts, {"highway": "residential", "name": "Travesia %d" % (row + 1)})

    # --- arterials --------------------------------------------------------
    b.way([(west, CENTER_LAT + 0.0009), (CENTER_LON, CENTER_LAT + 0.0004), (east, CENTER_LAT - 0.0011)],
          {"highway": "primary", "name": "Gran Via Demo", "ref": "N-1"})
    b.way([(CENTER_LON - 0.0015, south), (CENTER_LON + 0.0009, CENTER_LAT), (CENTER_LON - 0.0004, north)],
          {"highway": "primary", "name": "Paseo Central"})
    b.way([(west + 0.004, south), (west + 0.010, CENTER_LAT), (west + 0.006, north)],
          {"highway": "secondary", "name": "Ronda Oeste"})
    b.way([(east - 0.004, south), (east - 0.009, CENTER_LAT), (east - 0.005, north)],
          {"highway": "tertiary", "name": "Ronda Este"})

    motorway = []
    for step in range(24):
        t = step / 23.0
        motorway.append((west - 0.004 + (east - west + 0.008) * t,
                         north + 0.0035 + math.sin(t * 3.1) * 0.0011))
    b.way(motorway, {"highway": "motorway", "name": "A-99", "ref": "A-99"})
    b.way([(motorway[8][0], motorway[8][1]), (motorway[8][0] + 0.0012, north - 0.001)],
          {"highway": "motorway_link"})

    # --- river + lake -----------------------------------------------------
    river = []
    for step in range(40):
        t = step / 39.0
        river.append((west - 0.002 + (east - west + 0.004) * t,
                      south + 0.0032 + math.sin(t * 6.2) * 0.0016))
    b.way(river, {"waterway": "river", "name": "Rio Demo"})

    lake_cx, lake_cy = CENTER_LON + 0.013, CENTER_LAT - 0.0075
    lake = [(lake_cx + math.cos(a * math.pi / 12) * 0.0042 * (1 + 0.18 * math.sin(a)),
             lake_cy + math.sin(a * math.pi / 12) * 0.0026 * (1 + 0.18 * math.cos(a)))
            for a in range(24)]
    b.way(lake, {"natural": "water", "name": "Laguna Demo"}, closed=True)

    # --- park + forest ----------------------------------------------------
    park_cx, park_cy = CENTER_LON - 0.014, CENTER_LAT + 0.006
    park = [(park_cx + math.cos(a * math.pi / 9) * 0.0055,
             park_cy + math.sin(a * math.pi / 9) * 0.0038) for a in range(18)]
    b.way(park, {"leisure": "park", "name": "Parque Demo"}, closed=True)

    forest = [(east - 0.007, north - 0.0055), (east - 0.001, north - 0.0060),
              (east - 0.0008, north - 0.0015), (east - 0.0075, north - 0.0012)]
    b.way(forest, {"landuse": "forest", "name": "Bosque Demo"}, closed=True)

    # --- rail -------------------------------------------------------------
    rail = []
    for step in range(18):
        t = step / 17.0
        rail.append((west + (east - west) * t, south - 0.0022 + math.sin(t * 2.0) * 0.0009))
    b.way(rail, {"railway": "rail", "name": "Linea C-9"})

    # --- footpaths through the park --------------------------------------
    for k in range(5):
        angle = k * math.pi / 5.0
        b.way([(park_cx, park_cy),
               (park_cx + math.cos(angle) * 0.0050, park_cy + math.sin(angle) * 0.0034)],
              {"highway": "footway"})

    # --- a few service roads and steps (max-zoom only) --------------------
    for k in range(6):
        lon = west + (east - west) * (0.15 + 0.14 * k)
        b.way([(lon, CENTER_LAT - 0.002), (lon + 0.0008, CENTER_LAT - 0.0035)],
              {"highway": "service"})
    b.way([(CENTER_LON, CENTER_LAT), (CENTER_LON + 0.0003, CENTER_LAT + 0.0004)],
          {"highway": "steps"})

    return b


def main(argv: List[str]) -> int:
    path = argv[1] if len(argv) > 1 else "demo-city.osm"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(build().dump())
    print("wrote %s" % path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
