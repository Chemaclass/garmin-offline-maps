"""Unit tests for the per-tile area budget in ``mappack/pack.py``.

Filled areas draw first and cover what is under them. Left uncapped they
outrank minor roads and take the whole tile budget, which is how a city ringed
by farmland packed as a green field with no streets on it.
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)
from mappack.classify import GEOM_LINE, GEOM_POLYGON, Klass, L_GREEN_AREA, L_MINOR  # noqa: E402
from mappack.pack import AREA_BUDGET_SHARE, Feature, PackOptions, build_tiles  # noqa: E402


def square(cx, cy, half):
    return [(cx - half, cy - half), (cx + half, cy - half),
            (cx + half, cy + half), (cx - half, cy + half), (cx - half, cy - half)]


def line(cx, cy, n):
    return [(cx + i * 3.0, cy + (i % 2) * 3.0) for i in range(n)]


class TestAreaBudget(unittest.TestCase):
    """One huge polygon must not starve the roads drawn on top of it."""

    def tiles_for(self, features, budget):
        options = PackOptions(data_zooms=(14,), simplify_px=0.0,
                              max_points_per_tile=budget)
        return build_tiles(features, 14, 14, options)[0]

    def greedy_area(self, points):
        # Importance 50, the same as landuse=farmland, above L_MINOR's 45.
        return Feature(klass=Klass(L_GREEN_AREA, 0, GEOM_POLYGON, 50),
                       coords=square(400.0, 400.0, 60.0) * (points // 5),
                       length=10000.0)

    def road(self, n=20):
        return Feature(klass=Klass(L_MINOR, 0, GEOM_LINE, 45),
                       coords=line(380.0, 380.0, n), length=100.0)

    def layers_present(self, tiles):
        found = set()
        for feats in tiles.values():
            for f in feats:
                found.add(f.layer)
        return found

    def test_roads_survive_a_greedy_area(self):
        tiles = self.tiles_for([self.greedy_area(200), self.road()], 100)
        self.assertIn(L_MINOR, self.layers_present(tiles),
                      "a large polygon took the whole tile budget")

    def test_areas_still_get_drawn(self):
        tiles = self.tiles_for([self.greedy_area(20), self.road()], 200)
        present = self.layers_present(tiles)
        self.assertIn(L_GREEN_AREA, present)
        self.assertIn(L_MINOR, present)

    def test_areas_cannot_exceed_their_share(self):
        options = PackOptions(data_zooms=(14,), simplify_px=0.0,
                              max_points_per_tile=100)
        tiles = build_tiles([self.greedy_area(60) for _ in range(6)], 14, 14, options)[0]
        for feats in tiles.values():
            area_points = sum(len(f.points) for f in feats if f.layer <= 2)
            self.assertLessEqual(area_points, int(100 * AREA_BUDGET_SHARE) + 1)


if __name__ == "__main__":
    unittest.main()
