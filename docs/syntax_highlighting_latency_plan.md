# Syntax highlighting latency — bounded synchronous policy

**Status:** slice 3 implemented 2026-10-13. Current policy and checks follow;
the original investigation proposal below is historical context.

## Slice 3 implementation and rationale

`app/highlighting.ml` applies inclusive limits of **65,536 bytes and 2,000 lines**
using constant-time text-buffer metadata, before provider creation, validation,
diffing, parsing or querying. A trailing LF contributes an empty final line.
`Provider.highlight[_incremental] ~max_captures:16000` stops at the **16,001st**
cursor result, before decoding that result or normalizing any partial captures.
All results count, including unknown/internal captures and duplicates. Exactly
16,000 results are allowed. Provider calls without this option remain unrestricted
for differential references and stage benchmarks.

These limits retain ordinary project files, including the 50,707-byte
`core/editor.ml` with 9,612 normalized spans, while excluding the observed
205,000-byte/5,001-line generated source before any highlighting work. 64 KiB gives
the real editor source headroom; 2,000 lines catches highly fragmented small-byte
sources; 16,000 captures bounds range sorting/normalization for dense syntax even
well below the size limits. They are responsiveness heuristics, not time guarantees
or universal definitions of ordinary files. Some otherwise normal larger files
will deliberately lose syntax colors.

Fallback always creates an empty snapshot with the exact current document,
revision, language and query-configuration key. Status uses the existing
`Controller.highlight_status` plumbing (`Plain (Source_byte_limit 65536)`,
`Source_line_limit 2000`, or `Capture_limit 16000`). No notifications or feedback
overwrites. Native retained trees/providers are dropped on policy fallback.
Byte/line fallback recovers immediately once both limits fit. Capture fallback
latches the failing byte/line counts and skips provider work across small edits;
it retries after a 25% shrink in either dimension, explicit successful reload/reset
or language change. If still dense, the new failure becomes the shrink baseline.
Undo/shrink recovery parses fresh, never edits a stale retained tree. Same-size
syntax simplification alone does not release this latch; reload is an explicit retry.

No adaptive time-based disabling was added: one GC/scheduler outlier should not
unpredictably remove ordinary-file colors. The installed `tree-sitter.0.1.0`
binding exposes neither a parser timeout nor a query timeout/cancellation API.
The first dense call still pays parsing and up to 16,001 native cursor calls;
a native cursor call itself can be expensive. No post-hoc timing claims preemption.
Repeated input is guarded deterministically after capture overflow, but an
under-limit pathological parse/query can still stall. Whole-string editing/diff,
full-document querying within policy, and GC-finalizer native lifetime remain.

Two low-risk overhead improvements preserve capture overlap priority exactly:
capture categories are decoded once per compiled query, and normalization removes
the preliminary rank sort/dedup (the sweep's active set already deduplicates
identical ranges with identical endpoints). Ranking comparisons now short-circuit
without allocating comparison lists. Shortest capture, category priority, offsets
and category tie breakers are unchanged. Existing randomized per-byte overlap
oracle tests now also include duplicates; nested/crossing/tied/Unicode regressions
and fresh/incremental language differential tests remain.

### Before/after observations on this checkout

Linux, OxCaml switch `5.2.0+ox`. Wall times include controller editing/highlighting,
exclude rendering, and average 20 leading-space insertions. Initial time excludes
text-buffer construction; source load/validation is not made constant-time.

| Fixture | Bytes | Before mean / max edit ms | After mean / max edit ms | Before / after initial ms | After status |
| --- | ---: | ---: | ---: | ---: | --- |
| `core/editor.ml` | 50,707 | 15.544 / 18.280 | 8.761 / 9.777 | 45.107 / 28.760 | Highlighted |
| `core/text_buffer.mli` | 5,172 | 0.476 / 1.751 | 0.309 / 0.992 | 14.142 / 11.252 | Highlighted |
| Generated OCaml | 205,000 | 83.079 / 94.872 | 0.643 / 2.294 | 118.877 / 0.014 | Byte limit, zero parses |
| Generated empty lines | 2,000 | — | 0.010 / 0.011 | — / 0.037 | Line limit, zero parses |
| Dense integer list | 16,410 | — | 1.292 / 1.674 | — / 30.124 | Capture limit, one initial parse |

The live probe's provider-source fixture changed from 8,177 to 9,106 bytes, so its
1.472 → 1.140 ms/edit is not a same-source comparison. All fixtures verified exact
current snapshot keys, expected policy/parse counts, and no parses on 100 moves.
The dense fixture illustrates first-call versus recurring latency explicitly.

Unrestricted provider stage probe (CPU ms, automatic GC included), 205 KB OCaml:

| Mode | Before total / query / normalize | After total / query / normalize |
| --- | ---: | ---: |
| Fresh | 100.768 / 32.426 / 36.281 | 75.711 / 24.643 / 21.472 |
| Incremental | 78.698 / 33.987 / 31.713 | 54.395 / 25.544 / 18.024 |

At 41 KB, incremental CPU total fell 11.340 → 7.662 ms; at 410 bytes, 0.077 →
0.065 ms. The 230 KB interface benchmark remains unrestricted too (60.957 →
42.574 ms incremental). Cached frame checks still perform no parses; frame
timings are observational, not evidence of a rendering change in this slice.

### Commands and checks

All Dune commands below ran sequentially in the workspace. Both benchmark commands
ran before and after implementation; unrestricted stage coverage was retained.

```sh
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/syntax_live_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/syntax_incremental_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune build -j 10
opam exec --switch=5.2.0+ox -- dune runtest -j 10 highlight/test highlight_tree_sitter/test test screen/test
opam exec --switch=5.2.0+ox -- dune runtest -j 10
opam exec --switch=5.2.0+ox -- dune runtest -j 10 content_picker/host/test
opam exec --switch=5.2.0+ox -- dune build -j 10
opam exec --switch=5.2.0+ox -- dune runtest -j 10
```

Build, targeted highlighting/screen tests and final full test run passed. The first
full test run hit a picker-runtime test race reading an empty child PID string
(`Int.of_string: ""`, `content_picker/host/test/test_runtime.ml:156`); the isolated
picker rerun and subsequent full run passed without changes to picker code.
`git diff --check` also passed. Added tests cover inclusive byte/line boundaries,
initial bypass, stale-span rejection/current revisions, undo recovery, capture
early stopping and ignored/duplicate counting, retained-tree discard, repeated
edit suppression, reload retry/shrink, equal-revision language resets, rendered
plain syntax under overlays, rejection of an old colored snapshot and rendered
undo recovery. Existing animation/directory cache changes are retained.

## Original investigation proposal (2026-10-04)

Recorded after syntax-highlighting phases 1–6 were completed. The owner
accepted the palette and reported live behavior satisfactory; build, full tests
and three consecutive isolated smoke runs passed. See
[`syntax_highlighting_plan.md`](docs/archive/syntax_highlighting_plan.md) for historical checks.

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
opam exec --switch=5.2.0+ox -- dune build -j 10
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/syntax_incremental_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/syntax_live_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune runtest -j 10 --force
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
