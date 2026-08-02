"""Unit tests for ``mappack/geocode.py`` -- place-name search.

Nothing here touches the network. `search` takes an `opener` and the CLI takes a
`searcher` for exactly that reason: a test that needs Nominatim to be up is a
test that fails on a train.
"""

import argparse
import io
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)
from mappack import cli, geocode  # noqa: E402


def nominatim_response(*entries):
    """A fake urlopen returning a Nominatim jsonv2 body."""
    payload = json.dumps(list(entries)).encode("utf-8")

    class _Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            self.close()
            return False

    def opener(request, timeout=None):
        opener.request = request
        return _Response(payload)

    return opener


def entry(name, lat, lon, box, kind="city"):
    # Nominatim's boundingbox is south,north,west,east, as strings.
    south, north, west, east = box
    return {
        "display_name": name,
        "lat": str(lat),
        "lon": str(lon),
        "boundingbox": [str(south), str(north), str(west), str(east)],
        "addresstype": kind,
    }


class TestBboxAround(unittest.TestCase):
    def test_box_is_twice_the_radius_across(self):
        west, south, east, north = geocode.bbox_around(52.52, 13.40, 6.0)
        self.assertAlmostEqual(geocode.span_km(south, north, None), 12.0, places=2)
        self.assertAlmostEqual(geocode.span_km(west, east, 52.52), 12.0, places=1)

    def test_longitude_widens_towards_the_poles(self):
        equator = geocode.bbox_around(0.0, 0.0, 10.0)
        north = geocode.bbox_around(60.0, 0.0, 10.0)
        self.assertGreater(north[2] - north[0], (equator[2] - equator[0]) * 1.9)

    def test_centre_is_the_centre(self):
        west, south, east, north = geocode.bbox_around(40.4168, -3.7038, 5.0)
        self.assertAlmostEqual((west + east) / 2, -3.7038, places=6)
        self.assertAlmostEqual((south + north) / 2, 40.4168, places=6)

    def test_a_pole_does_not_produce_an_infinite_span(self):
        west, south, east, north = geocode.bbox_around(89.999, 0.0, 10.0)
        self.assertGreaterEqual(west, -180.0)
        self.assertLessEqual(east, 180.0)
        self.assertLessEqual(north, 90.0)

    def test_rejects_a_zero_radius(self):
        with self.assertRaises(ValueError):
            geocode.bbox_around(0.0, 0.0, 0.0)


class TestParseResults(unittest.TestCase):
    def test_reorders_the_bounding_box(self):
        payload = json.dumps([entry("Madrid, Spain", 40.4168, -3.7038,
                                    (40.31, 40.64, -3.88, -3.51))]).encode()
        place, = geocode.parse_results(payload)
        # south,north,west,east in -> west,south,east,north out.
        self.assertEqual(place.bounds, (-3.88, 40.31, -3.51, 40.64))
        self.assertEqual(place.lat, 40.4168)
        self.assertEqual(place.kind, "city")

    def test_empty_response(self):
        self.assertEqual(geocode.parse_results(b"[]"), [])

    def test_search_sends_the_user_agent_nominatim_requires(self):
        opener = nominatim_response(entry("Hamburg", 53.55, 10.0,
                                          (53.39, 53.73, 8.10, 10.32)))
        places = geocode.search("Hamburg", opener=opener)
        self.assertEqual(len(places), 1)
        self.assertIn("garmin-offline-maps", opener.request.get_header("User-agent"))
        self.assertIn("Hamburg", opener.request.full_url)


class TestResolveCity(unittest.TestCase):
    """The CLI glue: name in, bbox and pack name out."""

    def args(self, **over):
        base = dict(city="Madrid", bbox=None, input=None, name="map",
                    radius_km=6.0, city_index=0,
                    nominatim_url=geocode.DEFAULT_NOMINATIM_URL)
        base.update(over)
        return argparse.Namespace(**base)

    def parser(self):
        # argparse.error raises SystemExit(2); that is what we assert on.
        return argparse.ArgumentParser(prog="test")

    def searcher(self, *places):
        def search(query, url=None):
            search.query = query
            return list(places)
        return search

    def madrid(self):
        return geocode.Place("Madrid, Community of Madrid, Spain", 40.4168, -3.7038,
                             (-3.88, 40.31, -3.51, 40.64), "city")

    def test_sets_a_bbox_of_the_requested_radius(self):
        args = self.args()
        cli.resolve_city(args, self.parser(), self.searcher(self.madrid()))
        west, south, east, north = args.bbox
        self.assertAlmostEqual((west + east) / 2, -3.7038, places=6)
        self.assertAlmostEqual(geocode.span_km(south, north, None), 12.0, places=2)

    def test_names_the_pack_after_the_place(self):
        args = self.args()
        cli.resolve_city(args, self.parser(), self.searcher(self.madrid()))
        self.assertEqual(args.name, "Madrid")

    def test_an_explicit_name_wins(self):
        args = self.args(name="Home")
        cli.resolve_city(args, self.parser(), self.searcher(self.madrid()))
        self.assertEqual(args.name, "Home")

    def test_city_index_picks_a_later_match(self):
        second = geocode.Place("Madrid, Iowa, United States", 41.87, -93.81,
                               (-93.83, 41.86, -93.79, 41.89), "town")
        args = self.args(city_index=1)
        cli.resolve_city(args, self.parser(), self.searcher(self.madrid(), second))
        self.assertAlmostEqual((args.bbox[0] + args.bbox[2]) / 2, -93.81, places=6)
        self.assertEqual(args.name, "Madrid")

    def test_no_match_is_an_error(self):
        with self.assertRaises(SystemExit):
            cli.resolve_city(self.args(), self.parser(), self.searcher())

    def test_city_index_past_the_end_is_an_error(self):
        with self.assertRaises(SystemExit):
            cli.resolve_city(self.args(city_index=4), self.parser(),
                             self.searcher(self.madrid()))

    def test_a_lookup_failure_is_an_error_not_a_traceback(self):
        def boom(query, url=None):
            raise OSError("name resolution failed")
        with self.assertRaises(SystemExit):
            cli.resolve_city(self.args(), self.parser(), boom)

    def test_rejects_a_zero_radius(self):
        with self.assertRaises(SystemExit):
            cli.resolve_city(self.args(radius_km=0), self.parser(),
                             self.searcher(self.madrid()))


class TestArgumentWiring(unittest.TestCase):
    def test_city_and_bbox_together_are_refused(self):
        with self.assertRaises(SystemExit):
            cli.main(["--city", "Madrid", "--bbox", "-3.75,40.38,-3.65,40.45"])

    def test_input_with_city_is_refused(self):
        # --input used to beat both silently: the file was packed and shipped
        # named "map", with nothing on stderr.
        with self.assertRaises(SystemExit):
            cli.main(["--input", "x.osm", "--city", "Madrid"])

    def test_input_with_bbox_is_refused(self):
        with self.assertRaises(SystemExit):
            cli.main(["--input", "x.osm", "--bbox", "-3.75,40.38,-3.65,40.45"])

    def test_no_source_at_all_is_refused(self):
        with self.assertRaises(SystemExit):
            cli.main([])


if __name__ == "__main__":
    unittest.main()
