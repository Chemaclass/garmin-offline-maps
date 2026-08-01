---
name: contracts
description: Verify the cross-file invariants before committing — the three MapPack format implementations agreeing byte for byte, layer ids shared between classify.py and Palette.mc, and the generated artefacts being current. Use after any change to the binary format, varints, the packer, the palette, or TileReader.mc, or when a round-trip test fails and it is unclear which side drifted.
---

# Contract check

Three agreements are enforced by convention and by tests, not by the type
system. Run this before committing anything that touches bytes or colours.

The invariants are listed in
[docs/README.md](../../../docs/README.md#three-invariants); the field-by-field
spec is [docs/FORMAT.md](../../../docs/FORMAT.md). For a deep audit in its own
context, hand it to the `contract-auditor` agent.

## Run

```bash
make test
make demo && git diff --exit-code -- mapdata/active source/generated/MapIndex.mc
```

`tests/contract/test_tile_format.py` round-trips the writer against the
reference reader; `tests/contract/test_palette.py` checks the layer ids and the
renderer budgets. The `make demo` diff is exactly what CI runs — a diff there
means the committed pack is stale or something was hand-edited.

## If something fails

A `tests/contract/` failure means **go edit the other side**, not fix the test.
Work out which implementation is intended, then bring the others to it:

- **Format drift** → `pack.py`/`emit.py`/`varint.py`, `decode.py`,
  `source/TileReader.mc`, and `docs/FORMAT.md`. All four move together.
  `decode.py` must stay a line-by-line mirror of the Monkey C even where
  idiomatic Python would be shorter — that correspondence *is* the test.
- **Layer-id drift** → `classify.py`'s `L_*` are array indices into
  `Palette.mc`. Note `preview.py` parses `Palette.mc` at runtime, so a purely
  cosmetic reformat there can break the suite.
- **Generated diff** → regenerate, never hand-edit. If the diff is intended,
  commit it with the code change that caused it.

Then `make test` and `make lint` again.
