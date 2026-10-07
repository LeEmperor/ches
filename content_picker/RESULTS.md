# Phase 8 independent checks (2026-10-07)

Historical records below predate production acceptance. The current phase-8
production check record is in `../FILE_PICKER_PLAN.md`; production frontend tests
now exercise real cross-file navigation and dirty/stale/missing validation.

## Production phase-9 review (2026-10-07)

Build/full forced suites and `python3 scripts/picker_smoke.py` pass. The latter
checks real file/content opening, dirty/undo/stale validation, Unicode/TAB reveal,
catalog dispatch, zen/tiny/resize/interrupted paste and tty restoration using only
isolated `/tmp/opencode` fixtures. Directory workspace and full existing smoke
also pass after correcting the latter's stale `tile` palette count (17 → 18).
Exact logs/outcomes and defects fixed are in the current phase-9 plan handoff.
Human visual review, owner ranking examples and live performance acceptance remain
unperformed; historical failures/dependency records below are superseded, not erased.

## Production phase-8 checks (2026-10-07)

With `opam exec --switch=5.2.0+ox --`: build PASS; focused content/file/line/palette/
screen/source/frontend suites PASS; full `dune runtest --force` PASS. Final additional
LF/inactive-target regressions: `dune runtest ui/picker_test --force` PASS.
Read-only `git diff --check` PASS. Logs: `/tmp/opencode/phase8-final-{build,focused,full,ui}.log`.
Actual production Bonsai/rg acceptance and lifecycle tests passed. No terminal smoke,
human visual or performance acceptance claimed; those remain phase 9.

Toolchain: all Dune commands prefixed `opam exec --switch=5.2.0+ox --`.

| Check | Outcome |
| --- | --- |
| `dune build` | PASS |
| `dune runtest content_picker screen/test` | PASS after correcting new test/compiler issues |
| `dune runtest content_picker file_picker line_picker/test palette/test screen/test source/test --force` | PASS |
| `dune runtest` | FAIL only in pre-existing `ui/test/test_editor_view.ml` default-visible-tile snapshots |
| `git diff --check` (read-only) | PASS |

Nine provider/model Async tests and two headless tile tests use temporary trees,
real rg and a directly spawned fake executable. They assert ECHILD after child
reaping, not merely signal delivery. Tests cover exact structured raw byte fields,
multiple submatches and Unicode byte coordinates, literal/ignore policy, all
resource caps, failures/partial results, empty-query suppression, debounce,
spawn/cancel/refresh/root isolation, stalled-host timeout, stale installs and
once-only fake acceptance. Existing file/line/palette/screen/source suites pass.

No unrelated expectation was promoted; no baseline re-archive/rebuild performed.
Initial new compilation errors (assignment precedence, cursor type, deprecated
argv and wait API) and a test's incorrect assumption about shared word deletion
were corrected before final checks.

No live integration changed. Terminal smoke and human visual review not run.
No latency/p99/peak-RSS measurements or responsiveness claim made: tests establish
bounded resources and correctness, not live performance. No Git/GitHub mutations,
publication or attribution.

## Floating/runtime integration checks (2026-10-07)

Same toolchain prefix as above:

| Check | Outcome |
| --- | --- |
| `dune build` | PASS |
| `dune runtest content_picker screen/test ui/picker_test --force` | PASS |
| `dune runtest content_picker file_picker line_picker/test palette/test screen/test source/test ui/picker_test --force` | PASS; `/tmp/opencode/content-picker-phase8-focused.log` |
| `dune runtest --force` | FAIL only known `ui/test/test_editor_view.ml` snapshots; `/tmp/opencode/content-picker-phase8-full.log`; no promotion |
| `TMPDIR=/tmp/opencode bash scripts/smoke.sh --line-picker-only` | PASS; `/tmp/opencode/content-picker-phase8-line-smoke.log` |
| `TMPDIR=/tmp/opencode bash scripts/smoke.sh --palette-only` | PASS; `/tmp/opencode/content-picker-phase8-palette-smoke.log` |
| `git diff --check` (read-only) | PASS |

Five new subprocess/runtime-host tests assert bounded batches, raw byte intents,
empty/pending Enter, errors/caps, stale query/reopen rejection, paste/refusal/resize,
debounce, timeout and cancellation/replacement ECHILD reaping. Two shared host tests assert zen,
workspace/scroll/exact cancel restoration, cursor, focus and float replacement.
Two real-rg Bonsai frontend tests assert actual scheduling (300 files/600 Unicode
occurrences), query replacement/no-match/backspace, once-only typed consumption
after release, and interrupted paste/resize without leaking text into the document.

Initial new compilation/assertion issues were corrected before passing checks.
Content terminal smoke/human review not run: no live activation exists. No actual
file opening, latency/p99/RSS or release acceptance claim. Phase 8 remains PARTIAL.
