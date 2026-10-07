# Phase 8 independent handoff — historical PARTIAL (2026-10-07)

This historical handoff predates production integration. The current production
handoff is in `../FILE_PICKER_PLAN.md` (phase 8 software complete): `Space f g`,
palette activation, retained-session validation before tab activation, and actual
display-cell navigation are implemented. See README for dirty/failure policy.
Checks are in RESULTS. Phase-9 production software/terminal checks now pass; the
current phase-9 plan handoff supersedes stale blockers below. Human visual/ranking/
performance acceptance remains separate and unperformed.

## Done

Independent bounded Async rg JSON literal provider, raw-path/raw-line/byte-range
result model, query/run/root isolation, debounce, cancellation/reaping, errors and
visible result/query truncation; headless input/tile and once-only fake consumer.
No empty-query search; explicit on-disk/unsaved-exclusion label and byte coordinates.

Changed/added files:

- `content_picker/dune`, `model.ml`, `model.mli`, `README.md`, `RESULTS.md`, this file.
- `content_picker/provider/dune`, `provider.ml`, `provider.mli`.
- `content_picker/provider/test/dune`, `test_search.ml`, `fake_rg/dune`, `fake_rg.ml`.
- `file_picker/scope.ml`, `scope.mli`, `file_picker/discovery/provider.ml` (shared
  unchanged rg scope policy, no lifecycle rewrite).
- `screen/content_picker_tile.ml`, `.mli`, `screen/test/test_content_picker_tile.ml`,
  `screen/dune`, `screen/test/dune` (added library dependency, preserved phase 7).
- `dune-project`, generated `ches.opam` (Yojson/Base64 direct dependencies).
- `FILE_PICKER_PLAN.md` (phase 8 PARTIAL, precise independent done/blocked pending).

Checks/outcomes: `RESULTS.md`. Existing work preserved; no Git mutations, GitHub
publication/mutations or attribution.

## Pending dependencies — do not implement speculative adapters

1. Land shared floating compositor/palette migration; phase 5 remains blocked.
   Host must drive provider start/debounce and bounded yielded polling, call model
   `expect` only with the current request, reject old snapshots, handle focus,
   paste/cursor capture, Escape/Tab/Ctrl-c, minimum three content rows, resize and
   closing cleanup. No registry/binding/compositor currently uses this tile.
2. Land actual multi-buffer opening/activation + open-at-location API (phase 6).
   Current Controller owns one document and startup open can create missing files.
   **Do not wire this intent to startup open or pass byte columns to jump.**
3. Real consumer must release capture first, open/activate existing file without
   losing dirty buffers, validate expected line/literal against opened contents
   (including encoding/line-ending and dirty-buffer policy), convert raw byte
   boundary into that editor's navigation coordinate, and surface changed/missing
   file failures without damaging current buffer/focus. Policy remains unresolved
   until actual buffer API exists; no guessed implementation supplied.
4. Then choose/check nonconflicting live binding + command entry and verify actual
   opening/jumping, unsaved buffers, failure recovery, late events/paste, zen,
   small/resize terminals, viewport reveal, and terminal/human review.
5. Agree responsiveness target/dataset and measure live input-to-screen/p99/RSS.
   Current bounds are resource/record limits, not hard per-turn time guarantees.

Phase 7 partial and phases 1–4 remain intact. Phase 9 independent review/checks
were subsequently completed; see `../FILE_PICKER_PLAN.md`'s phase-9 handoff and
`../docs/pickers.md`. End-to-end release checks remain blocked by the dependencies
above. Leave branch reconciliation/publication to the human.

## Historical floating/runtime handoff (2026-10-07) — PARTIAL, superseded

- Shared float/focus/cursor/paste/resize and actual Async/Bonsai scheduling are
  implemented. No live activation or real cross-file acceptance exists.
- New `host/` runtime and five subprocess-host tests; two screen-host tests; two
  real-rg frontend tests. One batch per yielded 2ms poll, prompt query replacement,
  provider-owned debounce/kill/reap, exact run/root/query plus opening-generation
  freshness. Release owns the opening session across query changes. Empty requests
  do not launch rg; errors/truncation are visible through actual host frames.
- Typed intent is queued after closing/releasing capture/provider and consumed
  after UI installation. Raw path/expected line/literal and byte ranges unchanged.
  Future opening validation contract above remains required, not implemented.
- Changed files/exact checks: current phase-8 handoff in `../FILE_PICKER_PLAN.md`.
  Build/broader forced suites pass; full suite only known frontend snapshot failures,
  no promotion. Shared line/palette terminal smokes pass; no content visual sign-off.
- Next: human lands actual multi-buffer existing-file activation/open-at-location.
  Inspect exact API and dirty-buffer/encoding/failure policies before adapting;
  only then ship activation and verify open/jump/reveal/failure recovery. Phase 6
  and buffer management were not implemented. No performance/release claim.
- Preserved existing work. No subagents, mutative Git operations, GitHub mutations,
  publication or attribution.
