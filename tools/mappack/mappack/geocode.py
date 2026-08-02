"""Place-name search, so a pack can start from "Madrid" rather than a bbox.

Nominatim is OpenStreetMap's own geocoder: it takes a name and gives back a
centre and a bounding box. That turns

    make pack BBOX=-3.75,40.38,-3.65,40.45 NAME="Madrid"

into

    make pack CITY="Madrid"

which is the difference between a tool for people who own a map editor and one
for people who own a watch.

Two things are deliberate here:

* **The place's own bounding box is not used as the pack bounds.** Nominatim
  returns the administrative boundary, and for a capital that is the whole
  municipality -- Madrid's is roughly 40 km across, which packs to something no
  watch will hold. A pack is built from a radius around the centre instead, so
  the size is predictable from the arguments rather than from how a city drew
  its border. `--radius-km` is the knob; the place bbox is reported so you can
  see what you are cutting.
* **Ambiguity is not resolved silently.** "Springfield" is dozens of places.
  The caller gets every candidate and picks, rather than the packer guessing and
  someone discovering it after a 3 MB download.

Usage policy: Nominatim asks for no more than one request a second and a User-
Agent that identifies the application. One lookup per pack is well inside that,
and the User-Agent is shared with the Overpass client in `osmread`.
https://operations.osmfoundation.org/policies/nominatim/
"""

from __future__ import annotations

import json
import math
from typing import List, NamedTuple, Optional

from .geom import BBox
from .osmread import USER_AGENT

DEFAULT_NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
DEFAULT_RADIUS_KM = 6.0

#: Degrees of latitude per kilometre. Longitude shrinks by cos(latitude); see
#: `bbox_around`. Both are the spherical approximation, which is worth a few
#: metres over a pack this size -- the tiles are quantised far more coarsely.
_KM_PER_DEGREE_LAT = 111.32


class Place(NamedTuple):
    """One geocoder hit."""

    name: str
    lat: float
    lon: float
    #: The place's own boundary. Reported, not packed.
    bounds: BBox
    kind: str

    def describe(self) -> str:
        west, south, east, north = self.bounds
        return "%s  [%s]  %.4f,%.4f  span %.1f x %.1f km" % (
            self.name, self.kind, self.lat, self.lon,
            span_km(west, east, self.lat), span_km(south, north, None),
        )


def span_km(low: float, high: float, at_lat: Optional[float]) -> float:
    """Width of a degree range in km; pass `at_lat` for longitude, None for latitude."""
    degrees = high - low
    if at_lat is None:
        return degrees * _KM_PER_DEGREE_LAT
    return degrees * _KM_PER_DEGREE_LAT * math.cos(math.radians(at_lat))


def bbox_around(lat: float, lon: float, radius_km: float) -> BBox:
    """A west,south,east,north box of `radius_km` either side of a point."""
    if radius_km <= 0:
        raise ValueError("radius must be positive")
    dlat = radius_km / _KM_PER_DEGREE_LAT
    # cos() collapses at the poles; clamp so a silly latitude cannot produce an
    # infinite longitude span.
    scale = max(math.cos(math.radians(lat)), 0.01)
    dlon = radius_km / (_KM_PER_DEGREE_LAT * scale)
    return (
        max(lon - dlon, -180.0), max(lat - dlat, -90.0),
        min(lon + dlon, 180.0), min(lat + dlat, 90.0),
    )


def parse_results(payload: bytes) -> List[Place]:
    """Turn a Nominatim jsonv2 response into `Place`s, best match first."""
    places = []
    for item in json.loads(payload.decode("utf-8")):
        # boundingbox arrives as strings, ordered south,north,west,east --
        # which is neither the order we use nor the order the name suggests.
        south, north, west, east = (float(v) for v in item["boundingbox"])
        places.append(Place(
            name=item.get("display_name", "?"),
            lat=float(item["lat"]),
            lon=float(item["lon"]),
            bounds=(west, south, east, north),
            kind=item.get("addresstype") or item.get("type") or item.get("class") or "place",
        ))
    return places


def search(query: str, url: str = DEFAULT_NOMINATIM_URL, limit: int = 8,
           timeout: float = 30.0, opener=None) -> List[Place]:
    """Look `query` up, best match first. `opener` is for tests."""
    import urllib.parse
    import urllib.request

    params = urllib.parse.urlencode({
        "q": query,
        "format": "jsonv2",
        "limit": str(limit),
        # Cities and towns, not shops called "Madrid". Nominatim still ranks
        # within this, so an exact city name stays first.
        "featureType": "settlement",
        # English, so the country component is one spelling per country rather
        # than "Espana" beside "Spain" depending on who asked. The catalogue
        # groups by it, so it has to be stable.
        "accept-language": "en",
    })
    request = urllib.request.Request(
        url + "?" + params,
        headers={"User-Agent": USER_AGENT},
    )
    if opener is None:
        opener = urllib.request.urlopen
    with opener(request, timeout=timeout) as response:
        return parse_results(response.read())
