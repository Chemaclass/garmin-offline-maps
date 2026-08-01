"""Unit tests: one module in, no pipeline.

One file per ``mappack`` module, named after it. A test belongs here when it
exercises a single module's logic and nothing else -- fixtures as input data are
fine, wiring several stages together is not (that is ``tests/integration``).

    test_varint.py    -> mappack/varint.py
    test_geom.py      -> mappack/geom.py
    test_classify.py  -> mappack/classify.py
    test_osmread.py   -> mappack/osmread.py

``pack.py``, ``emit.py``, ``preview.py`` and ``decode.py`` have no file here on
purpose: everything they do is either a pipeline (``tests/integration``) or a
cross-implementation guarantee (``tests/contract``).
"""
