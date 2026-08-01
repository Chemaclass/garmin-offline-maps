"""Integration: generated artefacts -> preview renderer -> PNG.

``mappack.preview`` re-implements ``source/MapRenderer.mc`` in Python over the
*generated* artefacts, so exercising it covers the parts of the watch app CI
cannot compile: the generated MapIndex lookup, the jsonData block files, the
projection, and the tile addressing.

Needs Pillow; skips without it. The palette half of the renderer contract lives
in ``tests/contract/test_palette.py`` and runs unconditionally.
"""

import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)

from mappack import osmread  # noqa: E402
from mappack.emit import write_pack  # noqa: E402
from mappack.pack import PackOptions, pack  # noqa: E402
from mappack.preview import MapIndexFile, PackReader, render  # noqa: E402

# tests/integration -> tests -> mappack -> tools -> repo root
REPO = os.path.dirname(os.path.dirname(ROOT))
FIXTURE = os.path.join(TESTS, "demo-city.osm")
PALETTE_MC = os.path.join(REPO, "source", "Palette.mc")

try:
    from PIL import Image  # noqa: F401
    HAS_PIL = True
except ImportError:  # pragma: no cover
    HAS_PIL = False


@unittest.skipUnless(HAS_PIL, "Pillow not installed")
class TestPreviewRender(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        with open(FIXTURE, "rb") as fh:
            ways = osmread.read_osm_xml(fh)
        options = PackOptions(data_zooms=(12, 14, 16), name="Demo City")
        result = pack(ways, options)
        cls.pack_dir = os.path.join(cls.tmp, "active")
        cls.index_path = os.path.join(cls.tmp, "MapIndex.mc")
        write_pack(result, options, cls.pack_dir, cls.index_path, "(c) OpenStreetMap contributors")
        cls.index = MapIndexFile(cls.index_path)

    def render(self, **kwargs):
        return render(self.pack_dir, self.index_path, PALETTE_MC, **kwargs)

    def test_index_round_trips_every_declared_block(self):
        reader = PackReader(self.pack_dir, self.index)
        for (zoom, key), name in self.index.cases.items():
            slot = self.index.zoom_slot(zoom)
            block_x = (key >> self.index.key_shift) + self.index.origin_x[slot]
            block_y = (key & ((1 << self.index.key_shift) - 1)) + self.index.origin_y[slot]
            self.assertEqual(self.index.block_resource(zoom, block_x, block_y), name)
            self.assertIsNotNone(reader.block(zoom, block_x, block_y))

    def test_index_returns_none_outside_the_pack(self):
        self.assertIsNone(self.index.block_resource(14, 0, 0))
        self.assertIsNone(self.index.block_resource(13, 1002, 772))

    def test_renders_something_at_every_display_zoom(self):
        for zoom in range(self.index.data_zooms[0], self.index.max_zoom + 1):
            image, stats = self.render(zoom=zoom)
            self.assertGreater(stats["tiles"], 0, "no tiles at z%d" % zoom)
            self.assertGreater(stats["segments"], 0, "nothing drawn at z%d" % zoom)
            colours = {c for _count, c in image.getcolors(maxcolors=100000)}
            self.assertGreater(len(colours), 3, "z%d looks blank" % zoom)

    def test_zooming_in_shows_fewer_metres_across(self):
        far, _ = self.render(zoom=13)
        near, _ = self.render(zoom=16)
        self.assertNotEqual(far.tobytes(), near.tobytes())

    def test_rotation_changes_the_picture_but_keeps_the_centre(self):
        north, _ = self.render(zoom=15)
        turned, _ = self.render(zoom=15, heading=0.7)
        self.assertNotEqual(north.tobytes(), turned.tobytes())
        # The position marker is drawn at the centre either way.
        self.assertEqual(north.getpixel((227, 227)), turned.getpixel((227, 227)))

    def test_panning_moves_the_map(self):
        centred, _ = self.render(zoom=15)
        shifted, _ = self.render(zoom=15, lat=self.index.center_lat + 0.004)
        self.assertNotEqual(centred.tobytes(), shifted.tobytes())

    def test_day_and_night_differ(self):
        night, _ = self.render(zoom=15, night=True)
        day, _ = self.render(zoom=15, night=False)
        self.assertNotEqual(night.getpixel((5, 5)), day.getpixel((5, 5)))

    def test_venu3s_size_renders(self):
        image, stats = self.render(zoom=15, size=390)
        self.assertEqual(image.size, (390, 390))
        self.assertGreater(stats["segments"], 0)

    def test_far_outside_the_pack_is_empty_not_broken(self):
        _image, stats = self.render(zoom=15, lat=0.0, lon=0.0)
        self.assertEqual(stats["tiles"], 0)
        self.assertEqual(stats["segments"], 0)

    def test_cli_writes_a_png(self):
        out = os.path.join(self.tmp, "cli.png")
        result = subprocess.run(
            [sys.executable, "-m", "mappack.preview", "--pack", self.pack_dir,
             "--index", self.index_path, "--palette", PALETTE_MC,
             "--zoom", "15", "--out", out],
            cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.exists(out))


if __name__ == "__main__":
    unittest.main()
