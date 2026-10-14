# Editor performance test suite

Status: planned; implementation has not started.
Created: 2026-10-06.

## Goal

Preserve Ches's responsiveness as features accumulate, using repeatable measurements
and actionable regression reports. The owner's comparative requirement is:

> Ches should beat clean terminal Emacs on median and p99 latency for agreed
> everyday editing workloads. Neovim is the reference target; beating it is not
> required.

This is a goal to validate, not an existing performance claim. Define the workload
and configuration before evaluating it. Report individual scenarios; a favorable
aggregate must not hide a slow typing or movement case. A difference within measured
noise is inconclusive, not a win.

## Instructions for implementation sessions

- Read this document and applicable repository instructions before starting.
- Take one phase, or a clearly recorded slice of a phase, at a time. Check current
  code and Git status; preserve unrelated user work.
- Update the phase checklist and append a handoff entry before ending a session.
- Keep implementation, measurement results, and performance claims distinct.
- Do not optimize editor behavior merely to make the harness easier to satisfy.
- Build the measurement suite first; editor optimizations are follow-up work driven
  by measurements. Do not bundle storage, highlighting, or scheduler redesigns.
- Do not commit or stage changes unless the owner requests it.

## Measurement contract

### Three complementary layers

1. **Internal Ches probes:** attribute time and allocations to editing, highlighting,
   diagnostics, and frame construction. Useful for diagnosis, not direct competitor
   comparisons.
2. **Shared PTY harness:** launch each editor in a pseudo-terminal, inject input,
   parse terminal output, and detect its corresponding screen change. This is the
   primary comparative measurement.
3. **Real-terminal validation:** occasionally measure software input to captured
   screen changes, or physical input to display changes with external equipment.
   Keep these results separate from PTY timings.

The PTY metric is **input injection to the harness observing the expected terminal
screen state**. It includes editor scheduling, processing, output transport, and
harness observation overhead. It excludes terminal-emulator painting, compositor
and display latency, physical keyboard latency, and some terminal backpressure.
It is not keypress-to-photon latency.

Use a monotonic high-resolution clock. Define the start at the input-write attempt,
track partial writes/backpressure, and record any injection delay. Do not time only
CPU work or use adjustable wall-clock timestamps for elapsed intervals.

### Completion and correctness

- Parse output into a persistent terminal screen; do not stop at the first byte.
- Specify a scenario's completion predicate before implementing its timer: expected
  document cells, cursor position, viewport anchor, or another observable effect.
- Handle split escape sequences, UTF-8, alternate screen, resize, and the terminal
  features actually emitted by all three editors.
- Respect synchronized-update boundaries if an editor uses them. Detect unsupported
  screen-affecting sequences instead of silently accepting unreliable results.
- Answer terminal capability queries consistently so editors do not stall waiting
  for terminal replies. Record TERM and relevant negotiated capabilities.
- Ignore unrelated status updates and animation when detecting document completion.
  Disable optional animation explicitly in the baseline profile; later measure the
  normal user configuration separately.
- Readiness must have an observable predicate. A fixed sleep or output silence alone
  does not establish that an editor is ready, especially with animation enabled.
- Check final document state outside the timed interval. A fast incorrect operation
  is a failed measurement, not a successful sample.
- Timeouts, crashes, dropped inputs, unsupported features, and missing dependencies
  must be explicit. Never discard these samples silently or count them as zero.

### Fair comparison profiles

Start from `nvim --clean` and `emacs -Q -nw`, plus a documented Ches configuration.
These commands are starting points, not proof of feature equivalence.

- **Plain editing:** matching text fixtures, syntax highlighting and language services
  disabled, no user configuration or plugins.
- **Code editing:** explicit language/highlighting configuration per editor. Record
  implementation differences; stock Emacs may not provide the same language mode.
  If a comparable mode is unavailable, report that scenario as unavailable rather
  than comparing highlighted Ches with unhighlighted Emacs as though equivalent.
- **Background work:** controlled diagnostic/update workloads. Cross-editor results
  require equivalent producers and features; otherwise label them Ches-only.
- **Owner configuration (optional):** the owner's actual Emacs/Neovim setup, reported
  separately from clean baselines.

Use identical fixture bytes, terminal dimensions, starting cursor/viewport, and
semantic actions. Editor-specific mode-entry keys and setup stay outside timing.
Use isolated temporary HOME/config directories and scratch fixture copies; never
open user files for destructive benchmark operations. Record all overrides.

## Existing assets

Inspect these before adding new infrastructure:

- `source/bench/latency.ml`: headless key/batch turns plus `Frame.render`, 2,000-line
  fixture, diagnostics shown/hidden, median/p99/max output. Keys and batches are
  timed separately; this is not an actual overlapping-input burst measurement.
- `scripts/syntax_live_probe/probe.ml`: controller wall-clock latency, actual source
  files and generated large fixture; 20 edits, no terminal output measurement.
- `scripts/syntax_incremental_probe/probe.ml`: fresh/incremental provider CPU stages
  and cached frame construction; CPU times are not wall-clock input latency.
- `scripts/syntax_provider_probe/probe.ml`: provider resource/latency observations.
- `scripts/smoke.sh`: existing editor-driving experience; inspect for reusable setup
  ideas, but do not use tmux sleeps/capture polling as the precision timing method.
- `docs/syntax_highlighting_latency_plan.md` and the latency section of
  `docs/workspace_tiles_design.md`: historical local measurements and known costs.
  Paths and timings in historical documents may be stale; verify against current code.

Existing commands, run sequentially from the repository root:

```sh
opam exec --switch=5.2.0+ox -- dune exec source/bench/latency.exe
opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_live_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_incremental_probe/probe.exe
```

## Phase 1 — Define scenarios and result format

- [ ] Inventory installed editor versions, toolchain, and terminal-parser options.
- [ ] Choose harness language and a maintained terminal parser. OCaml is welcome but
  not mandatory; prefer reliable PTY/parser support over implementing a terminal.
  Record the dependency and reproducible installation method.
- [ ] Use a dedicated top-level `perf/` directory unless repository conventions at
  implementation time suggest a better location. Keep existing probes usable.
- [ ] Define a versioned machine-readable result format and scenario manifest.
- [ ] Define deterministic fixture generation and stable fixture hashes: small text,
  ordinary source (~2,000 lines), larger source (~200 KB), and a long-line case.
- [ ] Specify initial insert, backspace, movement, and scroll scenarios, including
  exact setup, reset policy, completion predicate, and final-state validation.
- [ ] Record baseline profile settings, including animation, panes, highlighting,
  terminal dimensions, and build mode.

Each run must record commit and dirty-tree status, executable/build identification,
editor versions and arguments, OS/kernel/CPU, toolchain, dimensions, TERM, fixture
hash/size, scenario/profile version, warm-up policy, and available power/runner
information. Keep UTC timestamps for run identity, monotonic time for durations.
Results include raw samples, sample counts, failures, and units—not only summaries.

**Acceptance:** another session can implement the initial scenarios from the manifest
without guessing what is timed or what constitutes completion. No timing gate yet.

## Phase 2 — Build and validate the PTY measurement engine

- [ ] Spawn, size, configure, and cleanly stop a child in a PTY, with timeouts and
  process-group cleanup on errors/interruption.
- [ ] Implement input injection, continuous output draining, terminal parsing,
  capability replies, readiness checks, and completion predicates.
- [ ] Keep synchronous logging and report generation out of the timed path.
- [ ] Add a small deterministic fake terminal application for harness verification:
  split output, unrelated output before the target, delayed changes, cursor-only
  changes, synchronized updates, Unicode, timeout, and child exit.
- [ ] Verify that incorrect output does not complete a sample and that intentionally
  delayed output produces approximately the expected additional elapsed time.
- [ ] Measure harness overhead with a minimal immediate-response application.
  Report this baseline; do not blindly subtract it from every editor sample.
- [ ] Add an untimed/debug transcript option for investigating failed predicates.

**Acceptance:** meaningful harness correctness tests pass, no processes remain after
failure, and measurement overhead/resolution is documented. Timing-sensitive harness
checks use generous bounds and are separate from ordinary deterministic unit tests.

## Phase 3 — Integrate Ches, Neovim, and Emacs

- [ ] Implement isolated launch/setup/teardown adapters for all three editors.
- [ ] Implement plain-text insert, backspace, cursor movement, and scrolling first.
- [ ] Restore identical fixture/cursor state between trials; document any intentional
  evolving-buffer sequence so file growth does not silently alter the workload.
- [ ] Validate semantic effects and final text for each editor outside timing.
- [ ] Handle absent executables with explicit unavailable results and instructions.
- [ ] Add a quick local comparison command and a thorough measurement command.
- [ ] Verify version/configuration recording and preserve raw per-editor results.

Prefer the shared PTY path over Neovim RPC/UI attachment for comparative results.
RPC is useful for separate investigations, but bypasses part of the terminal path.
Editor-specific APIs may assist untimed setup/validation if their side effects are
understood and recorded.

**Acceptance:** one command runs the same initial semantic scenarios across all
available editors and prints median/p95/p99, sample count, failures, and limitations.
Do not claim an editor ranking from a handful of development samples.

## Phase 4 — Add representative workloads and queued-input measurements

- [ ] Add code/highlighting profiles with documented feature differences.
- [ ] Cover edits near beginning/middle/end, newline insertion, multiline paste,
  undo, long lines, Unicode, and syntax changes spanning many lines.
- [ ] Separate typing/movement latency from bulk operations such as paste and open.
- [ ] Add paced typing at declared rates: inject according to a schedule rather than
  waiting for every previous screen change before sending the next input.
- [ ] Record intended injection time, actual injection time, and observation time;
  distinguish harness scheduling lateness from editor response and queue buildup.
- [ ] Define attribution when redraws coalesce multiple keys. Count coalesced or
  unobservable intermediate states rather than fabricating individual completion
  times; report time to visible progress and final catch-up where appropriate.
- [ ] Add actual overlapping diagnostic bursts for Ches, including panes hidden/shown.
  Do not describe separately timed key/batch turns as measured burst latency.
- [ ] Keep startup/file-open and optional memory observations in distinct reports.

**Acceptance:** reports expose queue buildup and large-file/tail behavior, with
correctness checks and explicit measurement boundaries for every scenario.

## Phase 5 — Establish baselines and regression policy

- [ ] Select and document a reference machine/build configuration.
- [ ] Collect repeated independent runs, warm-ups, and thousands of measured key
  samples per ordinary typing scenario where practical. State the sample count
  behind every p99; do not infer rare-tail reliability from 20 or 200 samples.
- [ ] Alternate/randomize editor and revision order to limit thermal/load bias.
- [ ] Report median, p95, p99, max, timeout/error counts, and run-to-run variability.
  State the quantile method. Preserve outliers unless a documented run-level fault
  invalidates the run; do not quietly trim stalls or pool away variability.
- [ ] Produce a same-machine comparison against clean Emacs and Neovim, plus a
  same-machine Ches baseline-versus-candidate comparison.
- [ ] Define a meaningful noise margin using repeated runs. Mark near-ties inconclusive.
- [ ] Agree with the owner which scenarios define the Emacs requirement, and adopt
  scenario-specific absolute budgets and relative regression tolerances.

Provisional aspirations for ordinary typing/movement on the reference machine are
median <=5 ms (ideally 1–2 ms) and p99 <=10 ms for the PTY response metric. Repeated
editor-caused stalls above 50 ms deserve investigation. These are proposed engineering
budgets, not universal standards, competitor measurements, or automatic gates.

A candidate fails the comparative goal if it only improves median while materially
worsening p99 on an agreed workload. If initial Ches results miss the goal, record
the gap and prioritize follow-up work; do not redefine the benchmark to pass it.

**Acceptance:** checked-in baseline summary, reproducible commands, environment
manifest, raw-result location, and owner-agreed policy. No cross-machine pass/fail
claim and no universal assertion that Ches is faster than Emacs.

## Phase 6 — Connect internal diagnostics and make the suite maintainable

- [ ] Give existing internal probes machine-readable output compatible with the
  reporting layer while retaining clear metric labels and standalone commands.
- [ ] Use monotonic elapsed timing where probes currently use adjustable wall clocks;
  preserve separately labeled CPU-stage measurements where useful.
- [ ] Add targeted internal scenarios only where PTY results identify attribution
  gaps. Keep instrumentation optional and account for its overhead.
- [ ] Preserve/add deterministic work invariants where meaningful: movement does not
  parse, unchanged revisions reuse appropriate caches, source queues remain bounded.
- [ ] Document quick checks, full comparisons, baseline updates, and interpretation.
- [ ] Integrate harness correctness checks into the normal test workflow; keep the
  full statistical benchmark explicitly invoked or on a dedicated runner.
- [ ] Start shared-CI timing runs as advisory reports. Enforce timing gates only on
  a sufficiently stable runner with measured tolerances and rerun policy.
- [ ] Keep generated artifacts out of Git by default; check in compact reviewed
  summaries/manifests and document durable storage of raw evidence.

**Acceptance:** future contributors can detect a regression, reproduce it, and
locate its likely stage without conflating CPU time, PTY response, and visible latency.

## Phase 7 — Validate the real terminal experience

- [ ] Pick a supported screen-capture/input-injection method for the owner's desktop,
  or an external camera/input setup. Record platform limitations and resolution.
- [ ] Compare the three editors in the same terminal, dimensions, font, compositor,
  refresh rate, and tmux arrangement (prefer no tmux for the initial baseline).
- [ ] Check normal typing, scrolling, optional cursor animation, and background load.
- [ ] Record software-injection/screen-capture versus physical-input/display results
  separately. Neither is interchangeable with the PTY metric.
- [ ] Investigate discrepancies: terminal output volume, update batching, animation,
  compositor scheduling, and synchronized-update behavior may change visible results.

**Acceptance:** a reproducible manual procedure and an initial observation report.
This phase can be periodic rather than an automated prerequisite for every change.

## Verification and completion policy

Run checks appropriate to each phase. Harness changes need correctness verification;
changes to editor code require relevant existing regression tests. Use the established
OxCaml switch for Dune commands, and avoid simultaneous Dune invocations. Do not
require competitor binaries for the normal Ches build or correctness tests.

Do not call a phase complete merely because its code exists: record commands run,
results, known limitations, and unmet acceptance criteria. A report should state
whether it establishes a comparison, diagnoses an internal cost, or only validates
the measurement machinery.

## Session handoff log

Append entries using this template:

```text
Date / session:
Phase and scope:
Files changed:
Decisions and reasons:
Commands and checks run:
Results / artifact locations:
Known limitations or blockers:
Checklist items completed:
Next concrete task:
```

### 2026-10-06 — Planning

- Created this phased plan from the owner's responsiveness goals and repository probe
  inventory. No harness, editor optimization, or timing enforcement implemented.
- Existing recorded timings are historical observations, not fresh baselines.
- Next task: Phase 1, choose the harness/parser and define initial scenario/result
  contracts before implementing the PTY engine.

### 2026-10-13 — Slice 5a, long-line rendering/navigation follow-up

- [x] Bounded snapshot-owned sparse line layouts and viewport glyph construction.
- [x] Cursor/fitted-scroll/preferred/scalar-column paths avoid recurring whole lines.
- [x] Deterministic full-layout equivalence, work bounds, edit/width invalidation,
  horizontal clipping and visual/block/beyond-EOL tests.
- [x] Explicit 1K/10K/100K left/right headless probe, targeted tests and build.
- Scope: measured editor optimization follow-up, not completion of the shared PTY
  performance-suite phases. Sole agent; previous slice work preserved.
- Files: `core/{cell_layout,text_buffer}.{ml,mli}`, `core/{editor,motion,block}.ml`,
  `screen/{frame,ui_state}.ml`, `test/test_line_layout.ml`,
  `screen/test/test_long_line.ml`, `scripts/long_line_probe/{dune,probe.ml}`,
  `docs/long_line_rendering.md`, this handoff log.
- Decisions, exact commands, measurements and remaining first-access/edit scans:
  see `docs/long_line_rendering.md`. Core/screen tests and core/screen/UI/binary build
  passed. Warm 100 KB render: 0.023 ms CPU left / 0.029 ms right; first right
  navigation: 1.223 ms CPU. Internal observations only, no timing gates.
- Next concrete task: session-label bookkeeping (owner's next slice); the PTY
  suite phase checklist remains separately planned.

### 2026-10-13 — Slice 6a, native picker / CLI fzf research

- Focused source audit and bounded lifecycle/filter comparison; production picker
  behavior unchanged. Sole agent, no git mutations, prior edits preserved.
- Created `docs/picker_performance_recommendation.md` and explicitly invoked
  `scripts/picker_comparison_probe/{dune,probe.ml,host_probe.ml,fzf_filter.py}`.
- Fresh 50K native cold: 256.929 ms / 82.436 MiB retained interaction delta;
  warm query progression 83–98 ms aggregate work; same-snapshot reopen 226.128 ms.
  fzf 0.44.1 fresh filter including IO: broad queries 79–81 ms, selective `model`
  28–29 ms, with different ranking and no native highlight/ID-mapping cost.
- Real-root 445-file Async host + eager frames: final cold 30.019 ms, edits
  8.522–12.047 ms, cleanup confirmed. No terminal/large-project latency claim.
- Probe build passed. Exact commands, source evidence, limitations and staged
  architecture are in the report; shared performance-suite phases remain planned.
- Recommendation: native indexed results + blank-query fast path first, then
  compiled/compact matching, bounded query reuse, discovery deltas and bounded
  refresh-validated reopen cache. No fzf terminal handoff or per-query backend now.
- Next concrete task: implement slice 6b from the report, preserving ranking,
  selection, generation guards and pending-acceptance semantics; then measure.

### 2026-10-13 — Slice 6b, indexed file results and blank-query fast path

- [x] Budget-built immutable chunked result index, stable ID-to-position lookup,
  cached counts/selection, indexed viewport/preview/acceptance; full results retained.
- [x] Blank/whitespace indexing without fuzzy preparation/scoring/rank-output pass;
  same-snapshot clear reuses the index, changed snapshots/close invalidate it.
- [x] Work-bound, ownership, deep movement/render/preview, selection/reorder,
  coalescing/stale/cancel/reopen tests; relevant palette/file/discovery/preview/host,
  screen and frontend tests plus binary/probe build passed.
- Final 50K blank: 16.615 ms / 4.410 MiB retained delta, versus 6a 256.929 ms /
  82.436 MiB; 391 turns, zero prepared entries. Clear: one turn, ~0.001 ms.
  Tile render 0.190 ms; blank Next+fit ~0.001 ms. Internal observations, not PTY.
- Tradeoffs recorded: first `m` now pays deferred preparation (313.776 ms); broad
  warm `mo` observed 134.063 ms versus 97.537 ms, due to extra result-index work.
  Small real host cold 34.139 ms, so no overall live-open speedup claim.
- Files, exact command history, final measurements and next-slice attribution:
  `docs/picker_performance_recommendation.md#slice-6b-implementation-handoff--2026-10-13`.
  Sole agent; no git mutations; earlier edits preserved. Later slices untouched.
- Next concrete task: 6c query-once/compact preparation, measuring combined cold
  blank + first query and ranked-output index overhead separately. Shared PTY-suite
  phases remain planned, independently of these measured editor optimizations.

### 2026-10-13 — Slice 6c, native compiled/compact scoring and shared result identity

- [x] File jobs compile query once, share compact basename/path text, reuse rolling
  score scratch, use single-scalar/exact fast paths and defer exact alignment to
  full result/viewport reads with a 128-row query-owned memoization bound.
- [x] Snapshot ID/ordinal index shared across queries; ranked output fills sparse
  ordinal-position chunks without per-query string map rebuilding. All results,
  stable ties/selection, pending/stale/cancel guards and display offsets preserved.
- [x] Independent legacy oracle/randomized policy/Unicode/weighted-field tests,
  bounded workspace/traceback, alignment ownership/eviction and ID-reuse invariants.
  Palette/line/file/discovery/preview/host/screen/frontend checks and builds passed.
- One 10K/50K probe: 50K first `m` 102.810 ms (6b 313.776), warm `mo` 43.335 ms
  (6b 134.063, 6a 97.537), `model` 23.178 ms. Combined blank + first query
  124.504 ms; 25.112 MiB retained post-query state, compact payload 4.26 MB.
- Tradeoffs: blank index now 21.694 ms / 5.982 MiB (6b 16.615 / 4.410); visible
  alignment and natural GC can exceed 2 ms; bounded traceback fallback can cost
  more CPU. No PTY latency or peak-RSS guarantee. Actual small host cleanup passed.
- Exact command history, files, evidence and limits:
  `docs/picker_performance_recommendation.md#slice-6c-implementation-handoff--2026-10-13`.
  Sole agent, previous work preserved, no mutative git operations.
- Next concrete task: 6d byte-bounded query-result reuse/safe narrowing; discovery
  deltas and runtime reopen cache remain separate later slices. Shared PTY suite
  phase checklist is unchanged.

### 2026-10-13 — Slice 6d, byte-budgeted completed-query reuse and safe narrowing

- [x] Generation/identity-scoped complete-query LRU: four entries / 96 MiB
  conservative reachable-ownership charge, including shared corpus/preparation,
  indices/arrays/compiled tokens and full alignment reservations. Exact and
  token-equivalent hits publish in one work turn with pending acceptance disabled.
- [x] Proper-subset narrowing only from complete, compatible folded-token prefix
  results; survivors rescored with original ordinals. No interrupted/partial set
  narrowing; changed snapshots clear cache, current selection/fallback retained.
- [x] Aligned-row memoization bounded by 128 rows / 256 KiB charged payload;
  oversized rows exact but uncached. Preparation rebind drops old candidate owners.
- [x] Cold-full/legacy oracle sequence equivalence, cancellation/output/generation,
  selection, eviction/byte reservation, oversized alignment and weak ownership
  tests; palette/line/file/discovery/preview/host/screen/frontend checks/build passed.
- One 10K/50K probe: 50K repeat/backspace hits examine zero candidates, one turn,
  ~0.001–0.002 ms work. New token extensions examine 10K rather than 50K candidates.
  Peak LRU charge 84,225,912 bytes <96 MiB; final live delta 26.738 MiB with four
  cached indices. Some uncached work rose modestly; no all-query speedup claim.
- Actual small host cached backspace: 4.045 ms / one injected batch (6c 12.698 /
  eight), cleanup verified. No PTY latency, p99 or global-RSS guarantee.
- Exact commands, files, budgets, evidence and limitations:
  `docs/picker_performance_recommendation.md#slice-6d-implementation-handoff--2026-10-13`.
  Sole agent, no git mutations, prior edits retained.
- Next concrete task: 6e discovery delta/progress/visible revision work, preserving
  cache completeness/generation and accounting rules; runtime reopen cache is 6f.
  Shared comparative PTY-suite phases remain separately planned.

### 2026-10-13 — Slice 6e, persistent discovery/progress and pure-work redraw suppression

- [x] Production delta/persistent-set polling without cumulative list rebuilding;
  stable intake IDs, bytewise tree ranking, continued intake/preparation/scoring and
  O(1)-root partial publication. New arrivals invalidate LRU but extend active work.
- [x] Explicit lifetime/content/preview revisions and shared Frame.Cache transition
  boundary: nonpublishing file work retains workspace/Notty base, while standard
  effect pumping and all other input/discovery/preview/dimension invalidation remain.
- [x] Streaming once-per-candidate, midstream edits, partial/status/caps/stale/reopen,
  final legacy-oracle/cache-addition/old-model and Notty base-build invariants;
  targeted discovery/file/host/preview/screen/UI/palette/line tests/build passed.
- One bounded probe: 50K persistent-set appends 20.904 ms; blank + fuzzy streamed
  work 124.997 ms, all 50K prepared/scored before final status, no final drain and
  no cumulative list materialization. No apples-to-apples two-query speedup ratio.
- Actual host: first `m` four injected batches / one base build, 4.956 ms (6d eight
  batches with eager frames, 11.760 ms); cold 25.349 ms / six injected base builds.
  Cleanup verified; no terminal/peak-RSS/quantile guarantee.
- Commands, files, measurements and limits in
  `docs/picker_performance_recommendation.md#slice-6e-implementation-handoff--2026-10-13`.
  Sole agent, no git mutation, prior edits preserved. No undo/LSP work.
- Next: 6f bounded runtime reopen ownership/freshness. Comparative PTY phases remain
  separately planned.

### 2026-10-14 — Slice 6f, validated runtime-owned reopen cache / final handoff

- [x] Data-only successful idle snapshots; per-runtime root/policy LRU, default
  two roots / 128 MiB conservative charge / 30-second monotonic validation TTL.
  Slot copy-on-write and weak-lifetime tests protect retired session ownership.
- [x] Blank/first-selection reopen with immediate cached rows and explicit refresh
  label. Fresh rg required every opening; acceptance blocked until successful full
  refresh/publication. Unchanged sets reuse indices/preparation/query entries;
  changed sets rebuild in bounded turns and prune deletions/ignore changes.
- [x] TTL, policy, byte/root limits, cancelled/failed/truncated refresh, stale work,
  ignore changes, zero-rebuild unchanged refresh and retired-session release tests.
- Small real-root host (451 files): cold immediate 0.026 ms / zero rows; cached
  immediate 0.012 ms / 451 rows, zero indexing/preparation, charge 1,298,646 bytes.
  Validation still took 21.177 ms (cold completion 25.351 ms); no latency guarantee.
  One synthetic 10K/50K lifecycle run, not repeated for missing truncated output.
- Final `opam exec --switch=5.2.0+ox -- dune build -j 10` and
  `opam exec --switch=5.2.0+ox -- dune runtest -j 10` passed. Picker PTY smoke passed
  (`/tmp/opencode/picker-terminal-5kxg6ln1`). Broader full smoke ran once and failed
  one blockwise delete/yank/paste saved-byte comparison (`blockop.txt`); other checks
  passed. Screens: `/tmp/opencode/ches-smoke-screens.IDj6iG`. This historical failure
  was subsequently diagnosed and resolved below; preserve it as failed-run evidence.
- Final architecture, measurements, commands and limits:
  `docs/picker_performance_recommendation.md#slice-6f-final-handoff--2026-10-14`.
  Native picker retained; previous fzf CLI observations are not terminal-equivalent.
  Human ranking/visual acceptance and comparative terminal/RSS quantiles remain open.
- Next agent: undo/text-storage work. Preserve this feature and extensive existing
  worktree edits; the broader blockwise smoke failure is closed as recorded below.

### Integration-failure closure — 2026-10-14

- [x] Replayed exact terminal block keys through keymap/editor in
  `test/test_keymap.ml`: delete, undo, redo, padded block paste, trailing LF, exact
  24-byte save payload and successful-save clean state all pass.
- [x] Root cause: immediate file comparison after `tmux send-keys Space w`, which
  queues input without waiting for Save. Historical failure's diagnostic `cmp`
  already saw equal bytes after capturing the successful `Wrote` frame.
  `scripts/smoke.sh` now waits for path-specific successful write completion and
  checks the unchanged expected bytes before and after exit.
- [x] `opam exec --switch=5.2.0+ox -- dune runtest -j 10 test screen/test` and
  `opam exec --switch=5.2.0+ox -- dune build -j 10 bin/ches.exe source/test/fake_lsp/fake_lsp.exe`
  passed sequentially; shell syntax check passed. Script has no nested Dune calls.
- Full smoke ran once: block scenario and both saved-byte assertions passed;
  one immediate negative LSP assertion after queued Undo failed. Capture already
  showed Undo completed and stop notice cleared. Screens:
  `/tmp/opencode/ches-smoke-screens.V8IULe`; output:
  `/home/wayne/.local/share/opencode/tool-output/tool_138334f7d001SPXOee40TlNXC5`.
- [x] LSP assertion now waits for Undo's restored cursor row, then preserves its
  negative notice assertion. New `--lsp-only` mode avoids repeating full smoke.
  Initial focused verification rejected an extra bottom-row status barrier because
  problems occupies that row; that extra barrier was removed. Final
  `TMPDIR=/tmp/opencode bash scripts/smoke.sh --lsp-only` passed all checks;
  screens `/tmp/opencode/ches-smoke-screens.J4qWgl`.
- Both observed blockers are closed. No single all-green full run is claimed for
  this slice; detailed historical failures, diagnosis and verification are retained
   in `docs/picker_performance_recommendation.md#integration-smoke-blocker-closure--2026-10-14`.

### 2026-10-14 — Slice 7a, bounded undo/history retention

- [x] Per-buffer code-configurable limits: 1,000 complete transactions / 64 MiB
  conservative soft charge budget across undo + redo. Preserve newest complete
  transaction even if oversized: charge <= max(budget, newest retained step charge),
  count <= configured positive limit. Active before snapshot is protected/excluded.
- [x] Incremental step charges include text, line-start arrays, fixed overhead and
  cached protected directory metadata estimate; shared snapshots deliberately charged
  per step. Bounded layout caches are additional, uncharged. Not an RSS guarantee.
- [x] Persistent ordered maps: O(log n) undo/redo/non-evicting commit, O(k log n)
  k-step eviction, direct root replacement for oversized commit/redo invalidation.
  No history-length traversal on keys or undo/redo, no list reversal spikes.
- [x] Small-limit tests: count/exact-byte/multiple eviction, oversized and zero-budget
  newest step, order/cursors, repeated undo/redo charge, active grouping, branch/no-op,
  weak collection, persistent old history, hidden identities, layout warming,
  save/dirty/selection and reload/directory-rebase limit preservation.
- Files: `core/{history,text_buffer,editor}.{ml,mli}`, `test/test_history.ml`,
  `test/test_editor.ml`, `README.md`, `docs/editor_reference.md`, this log.
- Exact sequential commands/results:
  - `opam exec --switch=5.2.0+ox -- dune runtest -j 10 test screen/test`: first attempt
    failed to compile a new stats assertion (test_result required compare). Replaced
    it with the exposed equality predicate; second attempt passed. Third attempt
    after multi-eviction/layout-accounting fixtures also passed.
  - `opam exec --switch=5.2.0+ox -- dune build -j 10`: passed full build.
  - `opam exec --switch=5.2.0+ox -- dune runtest -j 10`: passed full suite, including
    frontend/source integrations after the public Editor creation API change.
  - `git diff --check`: passed; repeated after final documentation edits.
- Sole agent, no subagents or mutative git operations; prior worktree edits preserved.
  Shared comparative PTY-suite phases remain separately planned; no performance/RSS
  measurement or terminal latency claim from these deterministic checks.
- Next concrete task: slice 7b text-edit copying, document scans/equality and line-index
  rebuild costs. Retention is bounded now, but large-file editing still copies/scans
  full text; saved/current/register/application ownership and externally retained old
  states remain outside the history estimate. Detailed policy/rationale: editor
   reference Storage section.

### 2026-10-14 — Slice 7b, text-edit copying and incremental line starts

- [x] Shared `Text_buffer.replace`/insert/delete implementation: one exact-size
  destination string with three blits, no temporary prefix/suffix strings, no
  intermediate deleted document in editor block replacements. Immutable whole-string
  storage remains deliberate; every nonempty edit still copies O(document bytes).
- [x] Binary-search replaced endpoints; remove covered line starts, count/fill LFs
  only in inserted text, copy prefix starts and shift suffix offsets. O(line count)
  array allocation/update remains except equal-length/no-newline edits, which share
  the immutable array. Required inserted UTF-8 validation remains O(inserted bytes).
- [x] Hidden identity deletion/normalization/insertion affinity preserved, including
  joined duplicate anchors, final empty rows, linewise removal and preserve-on-change.
  Identity deletion now uses indexed line ends rather than scanning each row's text.
  New text drops layouts; empty edits retain snapshots, except linewise identity removal.
- [x] Equality audit: editor dirty, block no-op and history transaction checks all
  use `Text_buffer.equal`; app open-buffer/directory/session dirty checks delegate
  to editor. Added safe physical snapshot/string/identity-list guards centrally.
  Distinct content is still compared; revision inequality is not used for dirty state.
  Distinct equal text/no-net-change checks remain potentially O(document bytes).
- [x] Independent whole-string oracle: 100 deterministic randomized sequences x 80
  edits, multibyte UTF-8, newline boundaries, both affinities, linewise/preserve
  policies and inserted hidden anchors; check bytes, lines, every boundary's
  `line_of_offset`, identities/scope and earlier snapshots after each edit.
  Added exhaustive small newline/empty/trailing-LF boundary replacements, validation,
  layout invalidation and unchanged retention-charge checks.
- [x] Deterministic work counters and GC allocation ceilings at 64 KiB / 205 KiB /
  1 MiB: exactly one destination, zero full-text newline-index scans, <=2 inserted
  newline-index bytes per ASCII insertion, zero on deletion; equal-length/no-newline
  allocation excludes a new line array. Ceilings reject temporary prefix/suffix
  copies and intermediate full documents. Counters exclude inserted UTF-8 validation;
  actual GC ceilings include all edit allocations. Scoped synchronous probe roots
  are restored on exceptions and retain no edited snapshots.
- Bounded undo slice 7a remains complete; full conservative charging of shared arrays
  and snapshots is unchanged, including newest-oversized-step policy and history limits.
- Files changed in this slice: `core/text_buffer.{ml,mli}`, `core/editor.ml`,
  `test/test_text_edits.ml`, `scripts/text_edit_probe/{dune,probe.ml}`, `README.md`,
  `docs/editor_reference.md`, this handoff. Prior worktree changes preserved; sole
  agent, no subagents or mutative git operations.

#### Exact sequential commands and results

1. `opam exec --switch=5.2.0+ox -- dune runtest -j10 test` — first attempt failed
   compiling a new allocation assertion: local `Float` open selected float `+` for
   integer budget arithmetic. Computed integer budgets outside the open.
2. Same command — passed.
3. `opam exec --switch=5.2.0+ox -- dune exec -j10 ./scripts/text_edit_probe/probe.exe`
   — passed; one bounded invocation, measurements below.
4. `opam exec --switch=5.2.0+ox -- dune build -j10` — full build passed.
5. `opam exec --switch=5.2.0+ox -- dune runtest -j10` — full suite passed.
6. After exhaustive boundary fixtures and ignoring supplied inserted identities for
   empty inserted text (matching delete-then-insert semantics):
   `opam exec --switch=5.2.0+ox -- dune runtest -j10 test` — passed.
7. `opam exec --switch=5.2.0+ox -- dune build -j10` — full build passed.
8. `opam exec --switch=5.2.0+ox -- dune runtest -j10` — full suite passed.
9. `git diff --check` — passed (also checked during implementation).
10. `uname -srmo` — Linux 6.8.0-142-generic x86_64 GNU/Linux.

#### One bounded internal observation

Default Dune build profile, switch `5.2.0+ox`, dirty worktree; generated ASCII LF
every 80 bytes, edit at midpoint of fixed input snapshot. Three warmups and 24
measured independent edits per case, naturally occurring GC included. CPU time
(`Sys.time`), not wall/PTY/key-to-screen time; median is mean of middle two sorted
samples. Allocated bytes use `Gc.allocated_bytes`, not retained memory or peak RSS.
Each case verifies final bytes outside timing. No stress, competitor comparison,
before/after speedup ratio, p99 or timing guarantee is claimed.

| Bytes | Edit | Median CPU ms | Max CPU ms | Allocated bytes/edit |
|---:|---|---:|---:|---:|
| 65,536 | insert ASCII | 0.0575 | 0.6120 | 72,552 |
| 65,536 | delete ASCII | 0.0305 | 0.4060 | 72,544 |
| 65,536 | replace ASCII | 0.0030 | 0.3380 | 65,984 |
| 65,536 | insert LF | 0.0060 | 0.2090 | 72,560 |
| 209,920 | insert ASCII | 0.0150 | 0.4110 | 231,376 |
| 209,920 | delete ASCII | 0.0220 | 0.4510 | 231,368 |
| 209,920 | replace ASCII | 0.0070 | 0.3110 | 210,368 |
| 209,920 | insert LF | 0.0150 | 0.3260 | 231,384 |
| 1,048,576 | insert ASCII | 0.1065 | 0.6210 | 1,153,896 |
| 1,048,576 | delete ASCII | 0.1075 | 0.5260 | 1,153,888 |
| 1,048,576 | replace ASCII | 0.0835 | 0.4870 | 1,049,024 |
| 1,048,576 | insert LF | 0.1050 | 0.5050 | 1,153,904 |

All cases reported one destination of exactly resulting text length and zero old-text
newline scan bytes; inserted index scan bytes were 2/0/1/2 respectively. The small
sample CPU distributions include GC/order noise (including the slower 64 KiB insert);
do not infer latency scaling or quantiles from them.

Remaining costs: O(document bytes) string copy; O(line count) changed arrays;
O(inserted bytes) validation/index scans; protected metadata normalization/list sort;
first-access layout scans; distinct-equal-string comparisons and other existing
highlight/render/application work. History budget is not global memory accounting.
No user decision is needed for this slice. Final orchestrator owns integration
verification; shared comparative PTY-suite phases remain separately planned.

### 2026-10-14 — Final integration review and verification

**Final software status: GREEN.** Final build/full suite and one all-green full
terminal run are now recorded after the latest core changes and review fix. Earlier
blockwise-save/LSP-Undo failures above remain historical evidence, not open blockers.
Sole agent; all intentional dirty/untracked task changes preserved; no subagents or
mutative Git commands. No performance probes or extra stress runs in this review.

Review breadth: whole dirty-tree status/diff inventory and high-level diff review
across app/core/source/screen/UI, picker/discovery/preview/matcher, interfaces,
tests, scripts and docs. Detailed source review concentrated on immutable text and
incremental line starts/hidden anchors, history charges/undo branching, snapshot-owned
lazy layouts, directory parser/session indexes, session source bookkeeping,
picker publication/reopen ownership and visible stamps, frontend cache invalidation,
and LSP pools/timers/launch/shutdown/reaping. This is a focused cross-feature review,
not an exhaustive line-by-line audit of every added test, probe or historical plan.

Concrete finding/fix: `source/lsp_client.ml` previously waited indefinitely for a
live child after stdout EOF. The new launch shutdown hold could therefore prevent
editor shutdown from finishing. EOF now permits normal exit during `shutdown_grace`,
then reports a protocol-stream failure and kills/reaps a surviving process. Added
`-close-stdout` fake-server mode and a real-child regression in
`source/test/{fake_lsp/fake_lsp.ml,test_lsp_client.ml}`: child closes stdout and stays
alive; test requires the stop event and reaping before editor quit. Ordinary exit
status/stderr handling remains covered. No additional concrete regression found in
the focused cache/ownership paths. Directory shared memos check exact immutable
inputs; edited text drops layouts; published picker aligners capture immutable
query/preparation roots; redraw reuse checks visible revisions rather than mutable
pointer identity. Updated editor reference and picker report status consistently.

Exact commands, all sequential, all **PASS / exit 0**:

1. `opam exec --switch=5.2.0+ox -- dune runtest -j 10 source/test`
   — includes the new live-EOF/reaping regression and existing pooled/coalesced LSP tests.
2. `opam exec --switch=5.2.0+ox -- dune build -j 10` — final full build.
3. `opam exec --switch=5.2.0+ox -- dune runtest -j 10` — final full-suite command;
   Dune reused already-green unchanged test aliases (no forced broad repetition).
4. `TMPDIR=/tmp/opencode bash scripts/smoke.sh` — one full run, **all checks passed**;
   block save/post-exit bytes, LSP Undo/restart/cleanup, editing/undo/Unicode/window
   scrolling, workspace/float/paste/resize and terminal restoration passed.
   Screens `/tmp/opencode/ches-smoke-screens.yaj6JY`; output
   `/home/wayne/.local/share/opencode/tool-output/tool_13849d53a001CTzZiDprhYNL3m`.
5. `python3 scripts/directory_editing_smoke.py` — pending edits/undo, refresh refusal,
   backing-path opening, dirty quit guard and apply boundary;
   fixture `/tmp/opencode/directory-phase6-pty-5uelvc59`.
6. `python3 scripts/directory_apply_smoke.py` — create/rename, dirty file/descendant
   reassociation, undo boundary and invalid-plan zero mutation;
   fixture `/tmp/opencode/directory-phase7-pty-_yw4nlui`.
7. `python3 scripts/directory_side_smoke.py` — side/major/hide, marks/Visual opens,
   partial failures, zen/tiny focus return, tabs/undo/last-close;
   fixture `/tmp/opencode/directory-phase5-pty-d7q2qmtz`.
8. `python3 scripts/picker_smoke.py` — file/content query/navigation/accept/cancel,
   dirty/stale/missing previews, Unicode locations, reopen/resize/interrupted paste,
   directory startup and tty restore;
   fixture/captures `/tmp/opencode/picker-terminal-9lji89tq`.
9. `git diff --check` — final whitespace check.

All executed smoke scripts were inspected before execution; none invokes Dune.
Directory captures: `/tmp/opencode/directory-phase{5,6,7}-pty.log`.

Integrated scope: directory parser/index caches; default-off opt-in smear and cached
animation base; bounded highlight fallback; shared LSP pools/coalesced negotiated
changes; lazy long-line windows; session/tab/source caches; native picker compact
matching/indexed/delta results and bounded query/reopen reuse; bounded undo and
one-copy edits/incremental line starts. Existing measurements/rationales above and
in the linked reports remain observations, not new integration latency claims.

Remaining explicit limitations: whole-document edit copies/changed line arrays and
first-access long-line seeking still scale with input; under-policy native
parse/query calls and oversized fuzzy alignment can still delay input; history and
picker estimates are soft/separate ownership budgets, not total RSS limits. LSP
sent-text history is count-bounded (32 per document), not byte-bounded, and closed-URI
version tombstones grow for a surviving pool's lifetime. Unversioned diagnostics
after reopen cannot distinguish an old lifetime's late response. These remain
documented follow-up considerations, with no failing required software check.
Human visual/cursor-shape/flicker/ranking acceptance and comparative PTY/RSS/quantile
measurement remain unperformed; the shared performance-suite phases stay planned.
