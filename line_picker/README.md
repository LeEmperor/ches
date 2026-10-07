# Current-document fuzzy lines (phase 7 software implemented)

`Ches_line_picker.Lines` captures the controller's immutable **in-memory** text,
including dirty edits. It performs no IO, project traversal or buffer opening.
`Ches_screen.Line_picker_tile` uses the shared transient floating host. In Normal
mode, `Space f l` opens it; the catalog command is **Search current document lines**
(`document.lines`). `Space f f` stays reserved/unbound until buffer opening exists.
The line command requires no ripgrep, disk reads or buffer manager.

## Host contract

- Create with the current controller. Schedule `work ~budget:128` with yields
  between turns, not by draining inside input/render callbacks. Rendering and
  query input do not prepare or rank entire documents.
- `validate` on controller transitions and before rendering. Identity, revision
  or immutable-text identity mismatch permanently invalidates/drops the snapshot,
  cache, results and job; reopen explicitly. Same path/revision is not identity.
  Cursor/feedback/save-only changes preserve validity. Reload starts a new identity.
- Enter while filtering or with no selected result is inert, not queued. Line
  number is selection identity; duplicate text remains separate. Old results may
  be shown while filtering but cannot navigate/accept. Selection survives reranking
  when still present, otherwise falls back to the first result.
- `accept ~current ~release` closes once and releases input/paste capture before
  rereading the current controller and revalidating. Install its successful
  returned controller synchronously and reveal the cursor using normal host view
  policy. `current` is a read-only getter. Errors do not edit/jump; the host must
  surface errors and restore focus. Cancellation releases once and never jumps.
- `Ui_state` owns Escape/Tab/Ctrl-c, paste isolation, prior-focus restoration, resize
  and shared floating geometry. Preferred 80×14, minimum 14×5, including zen;
  undersized resize closes and drops work. A fitting resize retains the query.
- `Editor_view` reuses the file host's one-scheduled-turn chain, yields through
  Async before each 128-record work input, and chains independently of redraws.
  Per-opening generations reject old turns; query jobs coalesce in the model.
  Closing/deactivation drops retained work. Successful acceptance installs the
  validated controller synchronously and uses normal scroll fitting to reveal it.

## Coordinates and limits

Matching uses shared loose-subsequence fuzzy policy, ASCII folding and whitespace
tokens, not typo correction/full Unicode folding. Raw line byte positions never
include line-number prefixes. The tile lays out whole lines before styling, so
matched runs do not reset TAB stops; controls are safely rendered as glyph escapes.
Jump targets the earliest matched raw byte (column 1 for blank query), converted
through `Editor.display_position_of_offset` using the editor's own width table.
Navigation is one-based display cells. Combining/zero-width scalars map to the
preceding visible glyph (or first cell): the existing display-cell jump cannot
address them independently. There is no guessed byte-as-cell conversion.

Preparation stops at the first exceeded cap: 50,000 lines, 8 MiB raw line payload,
or 4 KiB per line. The tile explicitly labels truncation. It includes empty and
final trailing-LF lines. Raw text is retained once by the snapshot plus copied
line/cache fields; decoded arrays/maps/result jobs add overhead beyond the payload
cap. A long line is size-checked before copying. Closing/invalidation releases
retained text/cache/results; the current editor still owns its document.

Record budgets are not hard latency bounds: matching DP, GC, final result reversal
and selection validation, list navigation/counting and tile fitting have additional
costs. Full-document scoring/sorting remains; limiting rendering is not ranking
optimization. No live/p99/peak-RSS guarantee is claimed.

## Reproducible scale probe

`opam exec --switch=5.2.0+ox -- dune exec line_picker/bench/latency.exe`

Single monotonic run, 2026-10-07; 1k/10k/50k generated source-like lines,
128-record work turns, initial blank preparation then cached queries. No terminal
or IO timing, no forced GC or repeated-percentile sampling. At 50k: initial blank
174.238 ms total / 2.518 ms longest turn; `m` 46.586 / 2.019 ms; `model` 97.848 /
1.354 ms; `let value` 139.959 / 1.415 ms; no-match `zzzz` 23.080 / 1.108 ms.
Broad queries require 782 turns. Cache decode assertions stayed at 50k across
queries. Actual Bonsai scheduling is now checked on 5k dirty lines and terminal
smoke on 500 lines, without manually draining the matcher. Longer lines/queries,
input-to-screen latency and an agreed target budget still need measurement.
Automated terminal smoke is not human visual acceptance.
