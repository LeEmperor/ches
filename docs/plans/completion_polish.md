# Completion responsiveness and richer snippet fields

## Scope

The old preference-persistence item is complete through executable `config.ml`.
Session toggles intentionally remain session-only; no preference writes are added.

This phase implements:

1. Initial whole-buffer word indexing outside input transitions, using bounded
   yielded work or a background execution path that actually allows input to run.
   Snippet/LSP candidates remain usable while words load. Snapshot/generation
   guards prevent obsolete results changing an installed completion or other file.
2. Choice fields `${1|posedge,negedge|}`, retaining linked occurrences and normal
   field navigation. Ctrl-e/Ctrl-y cycle a field's choices; Tab/Shift-Tab continue
   to navigate fields. Ordinary typing can replace a choice with custom text.
3. Filename variables `TM_FILENAME`, `TM_FILENAME_BASE`, `TM_DIRECTORY`, and
   `TM_FILEPATH`, resolved against the current document path for local and LSP
   snippets. Plain and braced forms plus literal fallback defaults are supported;
   unavailable values use a default or empty text. Transforms and nested defaults
   remain deferred. Validation accepts supported variables before a file exists.
4. Safe movement within an active field using Left/Right and Home/End. Movement
   clears the selected default; edits still mirror. Leaving the active field's
   occurrences cancels the snippet while retaining normal cursor movement.

## Boundaries and verification

- Index worker: completion word-index/model APIs, screen indexing/cache/request
  sections, UI indexing host/wiring. No snippet parser/session changes.
- Syntax worker: pure snippet parser/session choices and context expansion, local
  provider and LSP normalization. No screen/frontend edits.
- Interaction worker: snippet key handling/highlighting and terminal-independent
  key normalization, without changing screen indexing or host lifecycle sections.

Tests cover first-query bounded work, snapshot staleness and buffer switches,
choice escapes/mirrors/indentation, variable fallback/path handling, safe movement,
undo and lifecycle. Three agents maximum, six build jobs each, global cap20. No
Git staging/commits/pushes and no personal configuration changes.

## Status

Implemented and validated. Word indexing uses a yielded builder with a 16 KiB
work budget, including key copying and map-comparison estimates. One atomic map
operation may exceed a turn's budget; keys are capped at 4096 bytes. Recent edits
use bounded history lookup rather than comparing unchanged file bytes. Small
buffers and warm edits try one bounded step; remaining work runs through the
asynchronous host. One active build, one latest desired snapshot and one reply
slot prevent unbounded queues. Completed base builds can catch up across typing;
closed document caches and completed request references are released.

On an 8,000,001-byte/400,000-identifier benchmark, the initial input/query transition
was 13.828 ms with zero word-tokenized bytes. Index completion took 501.462 ms;
the largest scheduler heartbeat gap was 2.130 ms. These are headless observations,
not terminal latency guarantees; ordinary text-copy/edit costs remain. See
`screen/WORD_INDEX.md` for reproduction and continuous-typing limitations.

Choice parsing and cycling preserve mirrors, indentation, UTF-8 ranges and final
cursor affinity. The bundled `aff` now contains an edge choice. Filename variables
resolve against lexical editor paths in both providers. Unsupported unknown
variables/transforms/nested defaults remain explicit errors. Ctrl-e/Ctrl-y cycle
choices, while Tab/Shift-Tab visit fields. The visible hint bounds rendering work
independently of the number of alternatives. Safe Left/Right/Home/End navigation
retains the snippet and its undo group; leaving active occurrences cancels it.

Review fixed excessive unchanged-file comparisons, undercounted map work, retained
old index references, undo transaction splits on internal snippet movement, and
unbounded choice-hint construction. Regression coverage includes continuous typing
through initial build, stale results/cancellation, Unicode paths/mirrors, empty
coincident choices, terminal-prefix routing and ordinary Insert movement.

Final `dune build -j 12 @all`, `dune runtest -j 12`, and targeted review suites passed.
No personal configuration was modified. Preference persistence remains the
existing defaults → config.ml → session-only changes model.
