"""Integration tests: several pipeline stages wired together.

A test belongs here when it runs more than one module in sequence, or produces
real artefacts on disk. Named after the stage that is under test, not after
every module it touches.

    test_pack.py     -> osmread -> classify -> geom -> pack
    test_emit.py     -> pack -> emit -> jsonData resources + generated MapIndex.mc
    test_preview.py  -> generated artefacts -> preview -> PNG
"""
