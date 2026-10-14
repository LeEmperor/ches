# Slice 5a — long-line rendering and navigation

Implemented 2026-10-13. Headless internal measurements, not terminal latency or
competitor comparisons.

## Design and bounds

`Cell_layout.Index` is a lazy sparse layout over a valid UTF-8 line in the existing
backing string. Rendering does not copy `line_text`. Seeking computes widths but
does not build glyph strings/arrays for offscreen characters. Only intersecting
glyphs and their combining marks are materialized; positions and columns remain
relative to the **full** line. Existing full-array `Cell_layout` APIs retain their
semantics and continue to serve block editing operations.

Each index retains at most 256 checkpoints, with byte spacing
`max(256, ceil(line_bytes / 255))`, rounded forward to a code-point boundary.
Checkpoints include byte position, display column, code-point count and preceding
nonzero-width column. This preserves zero-width cursor geometry across checkpoint
boundaries. Already indexed seeks use binary lookup plus at most one checkpoint
interval (up to three extra bytes for boundary rounding); rendering additionally
decodes the visible content and trailing combining marks.

`Text_buffer` owns at most **64 line/width-function keys per text snapshot**, evicting
oldest-created entries on a miss. Width keys use physical function identity and
must describe stable width rules. The source string and line bounds belong to the
immutable snapshot, so document/revision number collisions cannot reuse another
text's layout. Text-changing insert/delete produces an empty cache. Identity-only
record copies may share indexes because the backing text is identical. There is
no global cache retaining documents. Each snapshot owns at most 16,384 checkpoint
slots; cached indexes live only as long as their owning snapshot or an explicit
index reference. Retained history snapshots can retain their own bounded caches.

Preferred columns, vertical/display navigation, code-point navigation, block
corners, cursor geometry, fitted scroll and the status cursor column use these
indexes. The status path was important: its previous whole-prefix code-point
count otherwise defeated right-edge viewport rendering. Rendering open-ended
blocks uses an open right edge without finding EOL; beyond-EOL insert padding is
clipped before allocation. Tabs are still split at block/point edges.

## Remaining linear work

- First distant access after load, eviction or a text edit scans the intervening
  prefix and builds checkpoints. With a fixed checkpoint count, interval size
  grows for extremely large lines; this is bounded-memory caching, not constant
  work for arbitrary byte lengths.
- Visible combining sequences require visiting every mark, even if they occupy
  no additional cells. Offscreen scanning allocates temporary decode/state values,
  but does not retain one glyph per offscreen character.
- Existing whole-string edits/line-start reconstruction, searches over viewport
  lines, and full block-edit layouts remain linear. Text edits invalidate all
  snapshot layouts; no rope or incremental text-storage redesign was made.
- More than 64 active line/width keys can evict and require reindexing.

## Verification

`test/test_line_layout.ml` compares indexed geometry and scalar positions with
full layout across 100 KB ASCII, wide/combining Unicode, tabs/control escapes,
leading and checkpoint-crossing combining sequences, EOL, edits, width identity
and eviction. Deterministic decoded-code-point bounds verify cold left and warm
distant access.

`screen/test/test_long_line.ml` compares complete styled window output with the
full-line oracle at both edges and checkpoint boundaries, including syntax,
search-like overlays, absolute byte selections and block overlays. Actual frames
are checked against full-line block/tab/insert-point oracles, including edits and
points beyond short-line EOL. Warm render/key work is bounded deterministically.
Existing core/screen Unicode, search, selection and block suites also pass.

All Dune invocations were sequential, using:

```sh
opam exec --switch=5.2.0+ox -- dune runtest -j 10 test screen/test
opam exec --switch=5.2.0+ox -- dune build -j 10 core screen ui bin/ches.exe scripts/long_line_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/long_line_probe/probe.exe
```

The test command was repeated during implementation; two early runs failed to
compile new tests (error-result conversion and a private span helper), then passed
after correction. No timing assertions are part of the suite.

## Headless probe observations

Linux, OxCaml `5.2.0+ox`, default Dune build, plain single ASCII line, 160×48,
highlighting and animation disabled. CPU time via `Sys.time`; allocation via
`Gc.allocated_bytes`, automatic GC included. Setup is outside each measurement.
Warm render/navigation means 100 samples. Right viewport setup first navigates
to the last character, so the separately measured first navigation indexes its
prefix before right rendering.

| Bytes | Left first / warm render ms | First right navigation ms | Right first / warm render ms | Warm adjacent navigation ms |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.055 / 0.025 | 0.013 | 0.028 / 0.036 | 0.006 |
| 10,000 | 0.024 / 0.023 | 0.143 | 0.026 / 0.023 | <0.001 |
| 100,000 | 0.025 / 0.023 | 1.223 | 0.028 / 0.029 | 0.004 |

Warm left allocations were ~140 KB/render at every size. Warm right allocations
were ~216/157/197 KB respectively. First right navigation allocated
~65 KB/713 KB/7.19 MB: temporary prefix scanning remains visible here. The supplied
audit's ~4.3 ms at 10 KB and ~36 ms at 100 KB motivated the change; it is not a
same-run CPU baseline. The retained probe is explicit and timing is observational.
