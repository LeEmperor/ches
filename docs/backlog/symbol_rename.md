# Ticket: language-server symbol rename

**Status:** Deferred — revisit on a later day; implementation has not started.
**Requested:** 2026-11-03.

## Goal

Rename the symbol under the cursor consistently across its server-identified uses,
including other files. Use semantic LSP edits rather than textual search/replace.

## Proposed interaction

1. Invoke **Rename symbol** from the command palette in a file's Normal mode.
   `Space r n` is a possible shortcut; check existing bindings before assigning it.
2. Use `textDocument/prepareRename` when supported to validate the position and
   obtain the current name/range. Otherwise follow the server's rename capability.
3. Prompt for the new name and request `textDocument/rename`.
4. Preview the affected files and edits, reusing the navigation/source-preview
   infrastructure where appropriate.
5. Apply the reviewed edits to buffers, leaving them unsaved for inspection and
   ordinary saving. Cancellation makes no text changes.

## First investigation

- Inspect the cloned **ocamllsp** and **slang-server** rename implementations and
  tests, then confirm the installed servers' advertised capabilities and responses.
- Establish what symbols each server can rename, including OCaml interface/source
  relationships and SystemVerilog elaboration/active-instance context.
- Inventory returned `WorkspaceEdit` forms: `changes`, versioned `documentChanges`,
  change annotations, and any create/rename/delete resource operations.
- Decide which forms the first version supports. Reject unsupported operations
  explicitly rather than silently applying only part of an edit.

## Implementation requirements

- Synchronize pending document changes before requesting rename. Keep requests
  asynchronous, cancellable, and guarded by document lifetime, revision, cursor,
  source session, and relevant Slang context.
- Convert ranges using negotiated position encodings against the correct target
  snapshot. Validate bounds, overlap, edit ordering and resource ownership.
- Preserve existing dirty buffers. Load unopened targets through normal session
  ownership without writing them automatically or losing unsaved text.
- Validate the entire edit set before adopting changes. If a target has changed
  since the request/preview, reject or recompute the operation; do not partially
  rename some files and leave others untouched.
- Recheck unopened target files before application; a preview is not a freshness
  guarantee. Failed or cancelled preparation must not leave incidental buffers or
  partial edits behind.
- Define multi-buffer undo semantics **before implementation**. Prefer a coherent
  rename transaction, but explicitly decide how later independent edits, buffer
  closure, and undo from different participating files interact.
- Update highlighting and language-server document synchronization through existing
  controller/session boundaries after successful application.
- Bound response size, preview work and affected-file counts with clear feedback.

## Acceptance criteria

- [ ] Capability-aware invocation and useful feedback for unsupported servers or
      positions that cannot be renamed.
- [ ] New-name prompt supports confirmation and cancellation; server errors leave
      all document text unchanged.
- [ ] Preview identifies every affected file and the proposed edits.
- [ ] Successful same-file and multi-file rename, including retained dirty buffers
      and previously unopened files, with no automatic disk writes.
- [ ] UTF-8/UTF-16/UTF-32 positions, Unicode names, multiple edits in one file, and
      overlapping/invalid edits are covered.
- [ ] Stale replies, edits during preview, server restart, buffer close/reopen,
      external file changes and active-instance changes cannot apply stale edits.
- [ ] Unsupported WorkspaceEdit operations fail explicitly without partial changes.
- [ ] The chosen multi-buffer undo/redo policy is documented and regression-tested.
- [ ] Scripted-server tests plus hands-on OCaml and SystemVerilog validation for
      the symbol kinds actually supported by the installed servers.

## Related work

- [LSP navigation](../plans/lsp_navigation.md): request ownership, exact positions,
  safe cross-file buffer navigation, and jump history.
- [Instances and references](../plans/instances_and_references.md): Slang context
  invalidation and server-provided symbol uses.
- [Navigation source previews](../plans/navigation_previews.md): bounded previews,
  dirty-buffer precedence, and destination freshness limitations.
- Existing atomic text edits in `core/text_edit.ml` and controller/session editing
  boundaries are useful primitives, but do not by themselves provide a multi-file
  transaction or coordinated undo.
