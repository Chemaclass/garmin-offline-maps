"""Unit tests for ``mappack/geom.py`` -- projection, simplification, clipping.

``source/Mercator.mc`` implements the same projection on the watch, so the
known-value checks here are what stop the two drifting.
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)

from mappack import geom  # noqa: E402


class TestGeometry(unittest.TestCase):
    def test_mercator_round_trip(self):
        for lon, lat in [(0.0, 0.0), (-3.7038, 40.4168), (13.405, 52.52), (-122.4, 37.8)]:
            for zoom in (12, 14, 16):
                x = geom.lon_to_world_x(lon, zoom)
                y = geom.lat_to_world_y(lat, zoom)
                self.assertAlmostEqual(geom.world_x_to_lon(x, zoom), lon, places=6)
                self.assertAlmostEqual(geom.world_y_to_lat(y, zoom), lat, places=6)

    def test_world_size_matches_zoom(self):
        self.assertAlmostEqual(geom.lon_to_world_x(180.0, 14), 256 * (1 << 14), places=3)

    def test_meters_per_pixel_known_value(self):
        # Equator, z0, 256 px tile -> ~156543 m/px is the standard constant.
        self.assertAlmostEqual(geom.meters_per_pixel(0.0, 0), 156543.03392804097, places=3)

    def test_simplify_keeps_endpoints(self):
        points = [(0.0, 0.0), (1.0, 0.02), (2.0, -0.01), (3.0, 0.0), (4.0, 5.0)]
        out = geom.simplify(points, 0.5)
        self.assertEqual(out[0], points[0])
        self.assertEqual(out[-1], points[-1])
        self.assertLess(len(out), len(points))

    def test_simplify_preserves_sharp_corner(self):
        points = [(0.0, 0.0), (5.0, 0.0), (5.0, 5.0)]
        self.assertEqual(geom.simplify(points, 0.5), points)

    def test_simplify_is_noop_below_three_points(self):
        self.assertEqual(geom.simplify([(0.0, 0.0), (1.0, 1.0)], 10.0), [(0.0, 0.0), (1.0, 1.0)])

    def test_clip_polyline_inside(self):
        points = [(1.0, 1.0), (2.0, 2.0)]
        self.assertEqual(geom.clip_polyline(points, 0, 0, 10, 10), [points])

    def test_clip_polyline_outside(self):
        self.assertEqual(geom.clip_polyline([(20.0, 20.0), (30.0, 30.0)], 0, 0, 10, 10), [])

    def test_clip_polyline_crossing(self):
        parts = geom.clip_polyline([(-5.0, 5.0), (15.0, 5.0)], 0, 0, 10, 10)
        self.assertEqual(len(parts), 1)
        self.assertAlmostEqual(parts[0][0][0], 0.0)
        self.assertAlmostEqual(parts[0][-1][0], 10.0)

    def test_clip_polyline_splits_on_re_entry(self):
        # out -> in -> out -> in -> out should yield two separate runs
        line = [(-5.0, 5.0), (5.0, 5.0), (5.0, 20.0), (8.0, 20.0), (8.0, 5.0), (15.0, 5.0)]
        parts = geom.clip_polyline(line, 0, 0, 10, 10)
        self.assertEqual(len(parts), 2)

    def test_clip_polygon_to_rect(self):
        square = [(-5.0, -5.0), (15.0, -5.0), (15.0, 15.0), (-5.0, 15.0)]
        clipped = geom.clip_polygon(square, 0, 0, 10, 10)
        self.assertGreaterEqual(len(clipped), 4)
        for x, y in clipped:
            self.assertGreaterEqual(x, -1e-9)
            self.assertLessEqual(x, 10 + 1e-9)
            self.assertGreaterEqual(y, -1e-9)
            self.assertLessEqual(y, 10 + 1e-9)

    def test_polygon_area(self):
        self.assertAlmostEqual(geom.polygon_area([(0, 0), (4, 0), (4, 3), (0, 3)]), 12.0)


if __name__ == "__main__":
    unittest.main()
