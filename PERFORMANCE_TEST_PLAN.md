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
