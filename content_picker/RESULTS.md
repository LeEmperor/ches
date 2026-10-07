# Phase 8 checks (2026-10-07)

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
