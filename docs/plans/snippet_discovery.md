# Snippet discovery and configuration navigation

## Commands

- **Insert snippet** opens a searchable floating picker of effective templates
  applicable to the current file (plus global entries). Prefix and description
  are searchable; the selected entry can show body, scope and origin as space
  allows. Accept inserts at the captured cursor, without consuming preceding
  identifier text, then activates placeholders through the existing snippet path.
  It works without LSP or automatic completion. Cancel makes no text changes.
- **Open configuration** opens the same XDG/HOME `config.ml` path used by the
  loader, using ordinary editor buffer ownership. An absent file opens an unsaved
  buffer rather than writing automatically. Errors use normal notifications.

## Architecture

Catalog inspection exposes effective declarations and provenance (bundled,
legacy JSON, OCaml). Explicit insertion by stable ID resolves filename variables
and indentation independently of prefix matching. Picker state is pure and bounded;
UI integration guards document lifetime/revision/cursor and rejects stale acceptance.
Configuration reload closes or refreshes a picker coherently.

The frontend resolves the configuration path outside pure screen transitions and
supplies it to screen state. Screen uses the established open-file path. No new
configuration writes or helper execution are caused by merely opening the file.

## Verification and policies

Tests cover scope/provenance, search/selection, empty results, Unicode clipping,
cancel, prefix-independent insertion and fields/undo, reload/buffer staleness,
XDG/HOME path and unsaved-config buffer reuse. Three agents, six jobs each,
at most20 aggregate. No Git mutation or personal config changes.

## Status

Implemented. `User_snippets.available` exposes scoped effective declarations and
provenance; `instantiate` resolves variables/indentation with a zero-width primary
edit. The pure picker searches prefix/description/ID and previews raw body, scope,
origin and ID when space permits. Screen captures document identity/revision/cursor
and catalog lifetime, uses ordinary insert-edit undo, and shares placeholder
activation with accepted completions. It is available in editable-file Normal mode.

Open configuration receives the loader's XDG/HOME path from the frontend and uses
ordinary session opening. Existing unsaved buffers are reused; absent files remain
unwritten. Path calculation does not execute config or perform filesystem work.

Review fixed explicit insertion after identifiers longer than the completion prefix
limit and bounded preview work before cell clipping, including combining-mark
floods. Regression tests cover exact middle-prefix insertion with variables/Unicode,
field/final cursors, single undo, stale captures/reloads, tiny viewports, cancel,
missing config, and unsaved-config reuse from split and tab layouts.

Full `dune build -j 12 @all` / `dune runtest -j 12` passed before review fixes;
post-fix `dune runtest -j6 screen/test completion/test ui/picker_test palette/test
ui/test` and `git diff --check` passed. No personal config or Git mutations.
