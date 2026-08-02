"""Contract: layer ids and render budgets shared with the Monkey C.

``classify.py``'s ``L_*`` constants are array indices into ``Palette.NIGHT`` /
``Palette.DAY`` / ``WIDTH_FAR`` / ``WIDTH_NEAR``. Nothing in either language
enforces that -- these tests do.

Also guards the frame budgets in ``source/MapRenderer.mc``, because the packer's
per-tile point budget is only safe relative to them.

A failure here means "go edit the other side", not "fix this test".
"""

import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
sys.path.insert(0, ROOT)

from mappack import classify  # noqa: E402
from mappack.preview import Style  # noqa: E402

# tests/contract -> tests -> mappack -> tools -> repo root
REPO = os.path.dirname(os.path.dirname(ROOT))
PALETTE_MC = os.path.join(REPO, "source", "Palette.mc")
RENDERER_MC = os.path.join(REPO, "source", "MapRenderer.mc")
CLASSIFY_PY = os.path.join(ROOT, "mappack", "classify.py")


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

    def test_layer_count_agrees_across_both_languages(self):
        """classify.LAYER_COUNT and Palette.mc's LAYER_COUNT are one number.

        Both say 10 and nothing checked that they still agreed. They are the
        length of the shared layer-id range, so a drift makes the packer emit a
        layer the renderer treats as out of range and skips, silently.
        """
        with open(PALETTE_MC, encoding="utf-8") as fh:
            source = fh.read()
        match = re.search(r"const LAYER_COUNT = (\d+);", source)
        self.assertIsNotNone(match, "Palette.mc no longer declares LAYER_COUNT")
        self.assertEqual(int(match.group(1)), classify.LAYER_COUNT)

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
        """The cap counts points *processed*, not lines drawn.

        It used to count drawn lines, which could not bound anything: with the
        geometry off screen nothing was drawn, so nothing incremented, so the
        cap never fired and the renderer walked every feature of every tile
        until the watchdog killed the app. Decoding is the cost; a point off
        screen costs nearly as much as one on it.
        """
        with open(RENDERER_MC, encoding="utf-8") as fh:
            source = fh.read()
        cap = int(re.search(r"MAX_SEGMENTS = (\d+)", source).group(1))
        self.assertGreater(cap, 200)
        self.assertLessEqual(
            cap, 800,
            "measured on a Venu 3 simulator: a downloaded Berlin renders at 400 "
            "(223 segments, 68 ms) and trips the watchdog at 1200")
        self.assertIn("_passWork += 1;", source,
                      "every point must count towards the budget, drawn or not")

    def test_areas_cannot_starve_the_road_pass(self):
        """Areas are drawn first; they need their own, smaller budget."""
        with open(RENDERER_MC, encoding="utf-8") as fh:
            source = fh.read()
        total = int(re.search(r"MAX_SEGMENTS = (\d+)", source).group(1))
        areas = int(re.search(r"AREA_SEGMENTS = (\d+)", source).group(1))
        self.assertLess(areas, total)
        self.assertIn("_passWork = 0;", source, "the budget must reset per pass")

    def test_a_screenful_of_tiles_exceeds_the_frame_cap(self):
        """A full screen of packed detail does *not* fit one frame, on purpose.

        This used to assert the opposite, and the assertion was wrong rather
        than the code: a screenful at the packer's default is 4400 points
        against a cap the watchdog holds near 400. Raising the cap to match the
        packer is what killed the app.

        So the renderer truncates by design, and the packer's job is to keep the
        *first* points of a tile the ones worth drawing. What must not happen is
        the cap quietly growing back to a screenful, so this pins the direction
        of the inequality rather than pretending it fits.
        """
        with open(RENDERER_MC, encoding="utf-8") as fh:
            cap = int(re.search(r"MAX_SEGMENTS = (\d+)", fh.read()).group(1))
        from mappack.pack import PackOptions

        self.assertGreater(
            PackOptions().max_points_per_tile * 4, cap,
            "if a screenful now fits the frame, re-measure on hardware before "
            "trusting it: this held at 400 and crashed at 1200")


if __name__ == "__main__":
    unittest.main()
