"""OpenStreetMap tags -> render layer + minimum zoom.

Layer ids double as draw order: the watch renderer iterates layers ascending,
so water goes down first and motorways go down last.
"""

from __future__ import annotations

from typing import Dict, Iterable, NamedTuple, Optional

# --- layer ids (keep in sync with source/Palette.mc) -----------------------
L_WATER_AREA = 0
L_GREEN_AREA = 1
L_BUILDING = 2
L_WATERWAY = 3
L_RAIL = 4
L_PATH = 5
L_MINOR = 6
L_TERTIARY = 7
L_PRIMARY = 8
L_MOTORWAY = 9

LAYER_COUNT = 10

GEOM_LINE = 0
GEOM_POLYGON = 1


class Klass(NamedTuple):
    layer: int
    minzoom: int
    geom: int
    # Higher wins when a tile runs out of its point budget.
    importance: int


_HIGHWAY: Dict[str, Klass] = {
    "motorway": Klass(L_MOTORWAY, 9, GEOM_LINE, 100),
    "motorway_link": Klass(L_MOTORWAY, 12, GEOM_LINE, 70),
    "trunk": Klass(L_MOTORWAY, 9, GEOM_LINE, 95),
    "trunk_link": Klass(L_MOTORWAY, 12, GEOM_LINE, 65),
    "primary": Klass(L_PRIMARY, 10, GEOM_LINE, 90),
    "primary_link": Klass(L_PRIMARY, 13, GEOM_LINE, 60),
    "secondary": Klass(L_TERTIARY, 11, GEOM_LINE, 80),
    "secondary_link": Klass(L_TERTIARY, 14, GEOM_LINE, 55),
    "tertiary": Klass(L_TERTIARY, 12, GEOM_LINE, 75),
    "tertiary_link": Klass(L_TERTIARY, 14, GEOM_LINE, 50),
    "unclassified": Klass(L_MINOR, 13, GEOM_LINE, 45),
    "residential": Klass(L_MINOR, 13, GEOM_LINE, 45),
    "living_street": Klass(L_MINOR, 14, GEOM_LINE, 40),
    "road": Klass(L_MINOR, 14, GEOM_LINE, 40),
    "pedestrian": Klass(L_PATH, 14, GEOM_LINE, 35),
    "service": Klass(L_MINOR, 16, GEOM_LINE, 20),
    "track": Klass(L_PATH, 14, GEOM_LINE, 30),
    "cycleway": Klass(L_PATH, 14, GEOM_LINE, 30),
    "footway": Klass(L_PATH, 15, GEOM_LINE, 25),
    "path": Klass(L_PATH, 14, GEOM_LINE, 30),
    "bridleway": Klass(L_PATH, 15, GEOM_LINE, 22),
    "steps": Klass(L_PATH, 16, GEOM_LINE, 15),
}

_RAILWAY = {"rail", "light_rail", "subway", "tram", "narrow_gauge", "funicular", "monorail"}

_WATER_NATURAL = {"water", "bay", "strait"}

_GREEN_LEISURE = {"park", "garden", "nature_reserve", "pitch", "golf_course", "common"}
_GREEN_LANDUSE = {
    "forest",
    "grass",
    "meadow",
    "recreation_ground",
    "village_green",
    "cemetery",
    "allotments",
    "orchard",
    "vineyard",
}
_GREEN_NATURAL = {"wood", "scrub", "heath", "grassland", "wetland"}


def classify(tags: Dict[str, str], include_buildings: bool = False) -> Optional[Klass]:
    """Return the render class for an OSM way, or None to drop it."""
    if not tags:
        return None

    highway = tags.get("highway")
    if highway is not None:
        k = _HIGHWAY.get(highway)
        if k is not None:
            # Tunnels are noise on a 1.4" screen; keep them but push them back.
            if tags.get("tunnel") in ("yes", "building_passage"):
                k = k._replace(minzoom=max(k.minzoom, 15), importance=k.importance // 2)
            return k
        return None

    railway = tags.get("railway")
    if railway in _RAILWAY:
        minzoom = 12 if railway in ("rail", "light_rail") else 14
        return Klass(L_RAIL, minzoom, GEOM_LINE, 60)

    waterway = tags.get("waterway")
    if waterway in ("river", "canal"):
        return Klass(L_WATERWAY, 11, GEOM_LINE, 85)
    if waterway in ("stream", "ditch", "drain"):
        return Klass(L_WATERWAY, 15, GEOM_LINE, 30)
    if waterway == "riverbank":
        return Klass(L_WATER_AREA, 11, GEOM_POLYGON, 88)

    natural = tags.get("natural")
    if natural in _WATER_NATURAL:
        return Klass(L_WATER_AREA, 9, GEOM_POLYGON, 98)
    if natural == "coastline":
        return Klass(L_WATERWAY, 9, GEOM_LINE, 99)
    if natural in _GREEN_NATURAL:
        return Klass(L_GREEN_AREA, 12, GEOM_POLYGON, 50)

    landuse = tags.get("landuse")
    if landuse in ("reservoir", "basin"):
        return Klass(L_WATER_AREA, 11, GEOM_POLYGON, 88)
    if landuse in _GREEN_LANDUSE:
        return Klass(L_GREEN_AREA, 12, GEOM_POLYGON, 50)

    leisure = tags.get("leisure")
    if leisure in _GREEN_LEISURE:
        return Klass(L_GREEN_AREA, 12, GEOM_POLYGON, 55)
    if leisure in ("swimming_pool", "water_park"):
        return Klass(L_WATER_AREA, 15, GEOM_POLYGON, 40)

    if include_buildings and tags.get("building"):
        return Klass(L_BUILDING, 16, GEOM_POLYGON, 10)

    return None


#: The leisure areas worth fetching as multipolygon relations. A subset of
#: `_GREEN_LEISURE` on purpose: a park can be a relation, a five-a-side pitch
#: never is, and relation queries are the expensive half of an Overpass call.
_RELATION_LEISURE = {"park", "garden", "nature_reserve"}


def _any_of(values: Iterable[str]) -> str:
    """An Overpass value regex matching exactly `values`, in a stable order."""
    return "^(%s)$" % "|".join(sorted(values))


# Overpass QL filter matching the classifier above. The value lists are built
# from the sets `classify` matches on rather than re-typed, so the query cannot
# ask for tags the classifier drops or miss tags it keeps. `way["highway"]` and
# friends have no list because the classifier takes them all and filters by key.
OVERPASS_FILTERS = (
    'way["highway"]',
    'way["railway"~"%s"]' % _any_of(_RAILWAY),
    'way["waterway"]',
    'way["natural"~"%s"]' % _any_of(_WATER_NATURAL | {"coastline"} | _GREEN_NATURAL),
    'way["landuse"]',
    'way["leisure"]',
    'relation["natural"="water"]',
    'relation["landuse"]',
    'relation["leisure"~"%s"]' % _any_of(_RELATION_LEISURE),
)


def build_overpass_query(south: float, west: float, north: float, east: float,
                         timeout: int = 180) -> str:
    bbox = "%.6f,%.6f,%.6f,%.6f" % (south, west, north, east)
    body = "\n  ".join("%s(%s);" % (f, bbox) for f in OVERPASS_FILTERS)
    return "[out:xml][timeout:%d];\n(\n  %s\n);\nout body;\n>;\nout skel qt;\n" % (timeout, body)
