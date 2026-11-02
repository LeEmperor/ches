# Automatic code completion

## Goal

Provide automatic Insert-mode suggestions from the current buffer and attached
language server. A cursor-adjacent menu shows candidates; an optional ghost suffix
previews the selected plain-prefix match. Completion starts enabled and can be
toggled in the command palette.

## Interaction

- First Tab inserts the selected candidate without closing the menu.
- Further Tab presses cycle forward; Shift-Tab cycles backward, with wraparound.
- Cycling replaces the same original slot, rather than querying the inserted word.
- Candidate order freezes after the first insertion.
- Ordinary typing accepts inserted text and starts a fresh query as appropriate.
- Escape keeps inserted text and follows Ches's existing return-to-Normal behavior.
- Enter accepts the selected candidate and dismisses the menu, without a newline.
- With no available candidates, Tab retains its existing editing behavior.
- Ghost preview is independently configurable; previews never modify the buffer.

## Architecture and delivery

1. **Pure model and atomic edits** (`completion/`, `core/`, `app/`). Candidate
   ranges use UTF-8 byte offsets in a captured snapshot. An atomic edit operation
   checks revision and ranges and joins the current Insert undo transaction.
   Cycling reverses the previous primary edit and applies the next, without
   exposing intermediate text. Additional edits (such as imports) apply only when
   finalizing the choice. Buffer-word work and candidate lists are bounded.
2. **LSP host integration** (`source/`, transport types in `error/`). Reuse pooled
   connections, flush document changes before requests, convert negotiated wire
   positions exactly, and correlate replies with resource/generation/revision and
   request identity. Advertise only supported completion capabilities. Initially
   omit snippet expansion and completion commands; reject unexpected snippet items
   rather than inserting snippet syntax.
3. **Screen and palette integration** (`screen/`, `input/`, `palette/`, `ui/`).
   Own completion sessions in the screen model, route asynchronous results without
   diagnostic Insert-mode deferral, render a clipped non-focus-taking menu, and
   honor existing terminal, paste, modal, and deferred-key routing.
4. **Integration validation and documentation**. Exercise actual key sequences,
   stale replies, edits/undo, Unicode, palette toggles, LSP synchronization, and
   existing regressions. Record scope and remaining limitations below.

## Correctness requirements

- Never block typing waiting for a server.
- Ignore obsolete replies and freeze choices while cycling.
- Do not apply additional edits for candidates merely visited while cycling.
- Never mutate buffer text for ghost rendering.
- A failed or stale edit leaves the document unchanged.
- Keep completion isolated across buffers and document lifetimes.

## Execution policies

No staging, commits, or pushes. Up to three general implementation agents with
separate file ownership. Each concurrent implementation worker may use at most six
build jobs; manager checks run after those builds finish, with at most 20 jobs.

## Status

Implemented and validated. Automatic suggestions start after two identifier
characters or selected punctuation. Buffer words sort lexically, with LSP
candidates ranked by server sort text before buffer-only suggestions. Ghost
preview defaults off; both palette toggles are session-local.

The first version deliberately excludes snippets, commands, resolve,
insert/replace edits, dynamic completion capability registration, and completion
list item defaults. Unsupported items are skipped. Buffer indexing scans the first
64 KiB; the combined candidate limit is 100. The host bounds pending requests to
one per document and 32 per connection, with a ten-second timeout.

Validation passed:

- `dune build -j6 @all`
- `dune runtest -j 12`
- After review fixes: `dune runtest -j 6 completion core app screen source`
  and `dune runtest -j 6 screen completion`.
- `git diff --check`

Headless coverage includes rendered menus/ghosts, palette toggles, forward/reverse
cycling, undo/redo, delayed Insert shortcuts, paste and terminal routing, Unicode,
buffer lifetimes, stale replies, synchronization ordering, cancellation, and
deferred additional edits with differing primary replacement ranges. A review
corrected initial proximity-based buffer sorting to the requested lexical order.
Interactive terminal appearance has not yet been manually evaluated.
