"""Contract tests: agreements that span implementations or languages.

These are the tests that fail when Python and Monkey C drift apart. They are
kept separate because they are not testing behaviour -- they are testing that
two hand-maintained implementations of the same thing still say the same thing,
and because a failure here means "go edit the other side", not "fix this code".

    test_tile_format.py -> pack.py (writer) vs decode.py, itself a line-by-line
                           mirror of source/TileReader.mc.  See docs/FORMAT.md.
    test_palette.py     -> classify.py L_* ids vs source/Palette.mc SLOT_* slots,
                           plus the render budgets in source/MapRenderer.mc.

Both correspond to invariants documented in docs/README.md.
"""
