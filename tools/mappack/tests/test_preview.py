"""Integration tests through the preview renderer.

`mappack.preview` re-implements `source/MapRenderer.mc` in Python over the
*generated* artefacts, so exercising it covers the parts of the watch app we
cannot compile on CI: the generated MapIndex lookup, the jsonData block files,
the projection, the tile addressing and the palette contract.
"""

import os
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from mappack import osmread  # noqa: E402
from mappack.emit import write_pack  # noqa: E402
from mappack.pack import PackOptions, pack  # noqa: E402
from mappack.preview import MapIndexFile, PackReader, Style, render  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
# tests -> mappack -> tools -> repo root
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
FIXTURE = os.path.join(HERE, "demo-city.osm")
PALETTE_MC = os.path.join(REPO, "source", "Palette.mc")
RENDERER_MC = os.path.join(REPO, "source", "MapRenderer.mc")
CLASSIFY_PY = os.path.join(os.path.dirname(HERE), "mappack", "classify.py")

try:
    from PIL import Image  # noqa: F401
    HAS_PIL = True
except ImportError:  # pragma: no cover
    HAS_PIL = False


class TestPaletteContract(unittest.TestCase):
    """Palette.mc and classify.py have to agree about layer ids."""

    def test_palette_has_sixteen_entries(self):
        style_night = Style(PALETTE_MC, night=True)
        style_day = Style(PALETTE_MC, night=False)
        self.assertEqual(len(style_night.colours), 16)
        self.assertEqual(len(style_day.colours), 16)

    def test_layer_slots_match_the_packer(self):
        with open(PALETTE_MC, encoding="utf-8") as fh:
            palette = fh.read()
        with open(CLASSIFY_PY, encoding="utf-8") as fh:
            classify = fh.read()

        pairs = [("SLOT_WATER", "L_WATER_AREA"), ("SLOT_GREEN", "L_GREEN_AREA"),
                 ("SLOT_BUILDING", "L_BUILDING"), ("SLOT_WATERWAY", "L_WATERWAY"),
                 ("SLOT_RAIL", "L_RAIL"), ("SLOT_PATH", "L_PATH"),
                 ("SLOT_MINOR", "L_MINOR"), ("SLOT_TERTIARY", "L_TERTIARY"),
                 ("SLOT_PRIMARY", "L_PRIMARY"), ("SLOT_MOTORWAY", "L_MOTORWAY")]
        for slot, layer in pairs:
            mc = int(re.search(r"const %s = (\d+);" % slot, palette).group(1))
            py = int(re.search(r"^%s = (\d+)$" % layer, classify, re.M).group(1))
            self.assertEqual(mc, py, "%s and %s disagree" % (slot, layer))

    def test_pen_width_tables_cover_every_layer(self):
        style = Style(PALETTE_MC)
        self.assertEqual(len(style.width_far), 10)
        self.assertEqual(len(style.width_near), 10)
        for far, near in zip(style.width_far, style.width_near):
            self.assertGreaterEqual(near, far, "near-zoom strokes should not be thinner")

    def test_day_palette_has_contrast_against_its_background(self):
        style = Style(PALETTE_MC, night=False)
        background = style.rgb(10)
        for layer in range(10):
            colour = style.rgb(layer)
            delta = sum(abs(a - b) for a, b in zip(colour, background))
            self.assertGreater(delta, 60, "layer %d is nearly invisible in day mode" % layer)

    def test_renderer_and_preview_agree_on_the_area_cut(self):
        """Both must treat layers 0..2 as filled areas."""
        with open(PALETTE_MC, encoding="utf-8") as fh:
            self.assertIn("layer <= SLOT_BUILDING", fh.read())
        self.assertEqual(Style(PALETTE_MC).area_layers, 3)

    def test_renderer_caps_work_per_frame(self):
        with open(RENDERER_MC, encoding="utf-8") as fh:
            source = fh.read()
        cap = int(re.search(r"MAX_SEGMENTS = (\d+)", source).group(1))
        self.assertGreater(cap, 500)
        self.assertLess(cap, 6000, "too many primitives per frame will trip the watchdog")

    def test_areas_cannot_starve_the_road_pass(self):
        """Areas are drawn first; they need their own, smaller budget."""
        with open(RENDERER_MC, encoding="utf-8") as fh:
            source = fh.read()
        total = int(re.search(r"MAX_SEGMENTS = (\d+)", source).group(1))
        areas = int(re.search(r"AREA_SEGMENTS = (\d+)", source).group(1))
        self.assertLess(areas, total)
        self.assertIn("_passSegments = 0;", source, "the budget must reset per pass")

    def test_packer_tile_budget_fits_a_screenful_of_tiles(self):
        """Four visible tiles at the packer default must fit the frame cap."""
        with open(RENDERER_MC, encoding="utf-8") as fh:
            cap = int(re.search(r"MAX_SEGMENTS = (\d+)", fh.read()).group(1))
        from mappack.pack import PackOptions

        self.assertLessEqual(PackOptions().max_points_per_tile * 4, cap * 2,
                             "lower --max-points-per-tile or raise MAX_SEGMENTS")


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
            cwd=os.path.dirname(HERE), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.exists(out))


if __name__ == "__main__":
    unittest.main()
