# Syntax highlighting latency — possible follow-up optimization

**Status:** proposal only; no optimization implemented or authorized by this file.
Recorded 2026-10-04 after syntax-highlighting phases 1–6 were completed. The owner
accepted the palette and reported live behavior satisfactory; build, full tests
and three consecutive isolated smoke runs passed. See
[`syntax_highlighting_plan.md`](syntax_highlighting_plan.md) for historical checks.

## Problem

Highlight updates run synchronously after the final text revision change in a
controller input event. Incremental parsing helps, but every update still queries
the full tree and normalizes all capture ranges. Larger documents can delay UI
response and queue subsequent inputs.

Movement, search, selection, scrolling, resize, animation and saves without text
changes do not parse. They can nevertheless wait behind an ongoing edit update.
Frame rendering is not the measured bottleneck.

## Existing measurements

Local measurements, not universal guarantees. Syntax complexity, capture density,
edit location and garbage collection matter alongside source size.

### Controller edit latency

Wall-clock averages over 20 successive leading-space insertions; includes editing,
snapshot update, parsing, query and normalization, but excludes frame rendering.

| Fixture | Bytes | Before incremental parsing | After | After maximum |
| --- | ---: | ---: | ---: | ---: |
| `core/text_buffer.mli` | 4,195 | 0.552 ms | 0.360 ms | 0.763 ms |
| `core/editor.ml` | 45,859 | 18.999 ms | 11.952 ms | 12.994 ms |
| Generated OCaml, 5,000 copies | 205,000 | 91.208 ms | 69.664 ms | 84.414 ms |

The large fixture's initial controller creation took about 111 ms. Around 70 ms
per edit can feel noticeably delayed; ordinary smaller files are much less costly.

### Provider stages on the 205,000-byte fixture

Mean CPU milliseconds, measured separately from the controller wall-clock probe:

| Stage | Fresh parse | Incremental parse |
| --- | ---: | ---: |
| Preparation: diff/copy/edit | 0.001 | 0.733 |
| Parsing | 29.659 | 8.840 |
| Full query/capture extraction | 28.852 | 29.230 |
| Range normalization | 31.233 | 29.024 |
| Complete provider call | 89.945 | 68.022 |

Totals also include source validation and small unclassified overhead. Automatic
GC is included. Cached 100x30 frame rendering averaged 0.112 ms for this fixture.
Do not directly equate CPU-stage times with wall-clock controller latency.

## Suggested investigation order

### 1. Reproduce and profile before changing algorithms

- Read applicable `AGENTS.md`, current provider/cache/snapshot interfaces and the
  original plan's freshness, ownership and style contracts.
- Rerun the existing probes on the current revision. Historical timings are not
  a substitute for a fresh baseline; record toolchain, fixture bytes and commands.
- Profile query/capture extraction and normalization CPU, allocations and GC.
  Also separate editing, validation and diff costs from provider work.
- Add representative real sources and edits near the beginning, middle and EOF,
  multiline paste, block edits, malformed syntax and comment/string delimiter
  changes. Generated repetitive sources and leading spaces are only one workload.
- Measure small-file regressions, large-file tail latency and bounded native-memory
  growth, not just average speed. Binding finalizers/external-memory accounting
  remain known limitations; do not force GC during editor input as a workaround.

### 2. Optimize full-query extraction and normalization first

These stages currently dominate. Investigate avoidable allocations, conversions,
sorting and repeated source scans while preserving validation and deterministic
overlap resolution. Prefer a bounded, benchmarked improvement over a broad rewrite.
Whole-string storage is a real cost, but these measurements do not justify making
a rope/piece-tree redesign the first highlighting optimization.

### 3. Consider incremental highlighting only under a separate correctness design

Changed syntax ranges alone do not identify every invalidated capture. A comment
or string delimiter edit can change syntax far below the edit or viewport; query
patterns and overlapping/nested captures can cross apparent change boundaries.
Define invalidation, offset adjustment, retained-capture ownership and conservative
full-query fallback before reusing previous highlights. Keep fresh parsing/querying
as the differential oracle throughout.

### 4. Consider background highlighting if responsiveness still requires it

This can keep input responsive without making query work cheaper. It requires
serialized/native-handle ownership, cancellation/coalescing or bounded queues,
document identity and revision/configuration tracking, stale-result rejection,
safe fallback and shutdown behavior. Never display old ranges against changed text.
Keep concurrency/effects outside the pure editor and respect existing library
boundaries; do not introduce Async into core/input/app incidentally. Background
execution is a separately scoped architectural change, not a small benchmark tweak.

## Relevant files and reproducible commands

- `highlight_ocaml/provider.{ml,mli}`: native session, parsing, capture extraction,
  stage timings and fresh/incremental entry points.
- `highlight/snapshot.{ml,mli}`: validation, overlap resolution and indexed lookup.
- `highlight/edit.{ml,mli}`: conservative UTF-8-safe snapshot diff and byte points.
- `app/highlighting.{ml,mli}`, `app/controller.ml`: revision cache and update boundary.
- `highlight_ocaml/test/test_incremental.ml`, `test/test_highlighting.ml`,
  `screen/test/test_live_highlighting.ml`: differential/integration regressions.

Run Dune commands sequentially in the established OxCaml switch:

```sh
opam exec --switch=5.2.0+ox -- dune build
opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_incremental_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_live_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune runtest --force
TMPDIR=/tmp/opencode scripts/smoke.sh
```

These commands are proposed for the future session, not rerun when creating this
note. See the original plan's phase 5 handoff for the exact recorded benchmark run.

## Acceptance and scope boundaries

- Compare normalized ranges and statuses with fresh results after edit sequences,
  including Unicode, EOF, malformed code, multiline comments/strings, undo/redo,
  reload, paste and block operations. Preserve immutable historical snapshots.
- No parser work on unchanged/non-text events; no stale snapshot application.
- Preserve overlays, safe special-character display, geometry, text bytes, revision,
  registers, history, dirty/save behavior and `%` semantics.
- Report before/after stage and end-to-end latency, allocation/memory observations,
  tail latency, small-file regressions and remaining full-document costs honestly.
- Full build/tests and smoke must pass; interactive responsiveness/flicker needs
  real-terminal review. Do not silently promote changed snapshots.
- No extra languages, semantic tokens, theme/config engine or editing/storage
  redesign bundled into this work. Obtain approval for dependencies/switch changes.
- The owner manages Git: no staging, commits, pushes or other mutative Git operations.
  Update this note with findings, exact checks and a durable handoff when work begins.
