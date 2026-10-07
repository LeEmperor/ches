# Phase 8 handoff — PARTIAL (2026-10-07)

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
