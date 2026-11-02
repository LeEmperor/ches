# Project status

[Documentation index](README.md) · [Development](development.md)

This page collects support boundaries, implementation limitations, and validation
notes that previously lived in the repository README. User-facing controls are
documented in the [editor reference](editor_reference.md).

## Support and configuration

Ches is developed for a local Linux workflow. Its toolchain, keybindings, and
runtime defaults are maintained in the repository; it is not currently packaged
for general distribution. See [development](development.md) for the toolchain.

Files accept UTF-8 text with LF line endings, preserving whether the original
ends with a newline. CR line endings, NUL bytes, special files, and invalid UTF-8
file contents are rejected. Editing requires terminal standard input;
`--list-themes` requires neither a terminal nor a file path.

The current startup defaults are Vim Classic and framed Zen. `--workspace`,
`--bare` / `--superzen`, and `--theme NAME` provide startup overrides. Keybindings
and editing defaults are defined in code. Layout preferences and history are
session-local rather than saved across editor restarts.

## Feature scope

- **Editing:** Normal, Insert, characterwise/linewise/blockwise Visual, counts,
  motions, delete/yank operators, undo/redo, autoindent, two-space soft tabs,
  literal search, and conflict-marker navigation/resolution.
- **Workspace:** file tabs with independent text, undo, cursor and scroll;
  configurable supporting tiles, status placement, read-only selection/copying,
  Zen, and Bare presentation.
- **Navigation:** a command palette, fuzzy current-document and project-file
  pickers, literal on-disk project search, and editable directory listings.
- **Tile Terms:** lazy numbered shells with per-session output, jobs, exit state,
  and size preferences; terminal Normal/Visual inspection and copying; universal
  timed Insert-mode toggles. Linux PTYs and vendored libvterm provide terminal
  emulation. One float is visible at a time; no built-in scrollback browser,
  mouse forwarding, docking, or cross-restart shell restoration.
- **Themes:** live preview and dark/light palettes, including monochrome,
  retro-terminal, and warm paper variants. `--list-themes` is the live catalog.
- **Highlighting:** incremental Tree-sitter parsing for OCaml, Verilog,
  SystemVerilog, and AT&T/GAS assembly (`.s` / `.S`).
- **Diagnostics:** `ocamllsp` for OCaml and `slang-server` for Verilog/SystemVerilog,
  with freshness tracking, a problems view, and restart controls. Language-server
  integration consumes diagnostics only.
- **Git:** stage/unstage/discard files, hunks, and selected diff lines; commit,
  amend, and extend HEAD; fetch, pull, push; branch checkout/creation/merge;
  stopped merge/rebase resolution; logs and file history. See the
  [VCS guide](editor_reference.md#vcs-view) for controls and behavior.

## Current limitations

### Saving and external changes

Writes are synchronous and in place, without atomic replacement or `fsync`. A
failed write can leave a truncated file. External file changes are not detected;
`:e!` explicitly discards changes and reloads the file.

### Document scale and undo

Edits still copy the whole immutable document string into one exact-size
destination with blits. Line starts update from the edited range and inserted
text without rescanning unchanged document bytes; equal-length/no-newline edits
reuse the array.

Highlighted files still query the full syntax tree after each change. Files above
64 KiB, 2,000 lines, or 16,000 captures fall back to plain text to limit synchronous
work. See the [editor reference](editor_reference.md) for fallback and recovery.

Undo retains whole-text snapshots, bounded per buffer to 1,000 complete
transactions or a conservative 64 MiB soft charge budget. The newest complete
transaction always survives, even if oversized. Limits are configured in code
through `History.Limits` and `Editor.create ~history_limits`.

These limits bound history retention estimates, not total RSS; active/saved text
and bounded per-snapshot layout caches are additional. Large-file edits remain costly.

### Unicode and display

Movement and deletion use code points rather than grapheme clusters. CRLF is
unsupported, and long lines scroll horizontally rather than wrap.

### Directory operations

Directory saves apply filesystem changes directly, including permanent deletion
of omitted files/links or empty directories. There is no trash or confirmation
dialog, and text undo does not undo filesystem changes. See the
[directory guide](directory_workspace.md) before using editable listings.

Linux `renameat2(RENAME_NOREPLACE)` is required. There are no cross-device moves,
nonempty directory deletion, filesystem undo, rollback, watchers, or
crash-persistent intent. Partial apply can leave staging names; retries retain
unresolved intent only within the running session. Copies preserve rwx bits, not
ownership, timestamps, ACLs, xattrs, or hard-link relationships.

### Sessions and tooling

Visited directories are retained without eviction. Language servers are shared by
workspace root and configuration; document changes are coalesced and use
incremental synchronization when supported. The synthetic checker retains
per-file runtimes. There is no cross-restart session persistence or support for
multiple editor groups.

Editing offers literal search, an unnamed register, and a limited `:` prompt.

### Version control

The VCS view has no blame, stash, cherry-pick, or interactive rebase. Only the log
popup remembers its switches. Authentication uses ssh-agent or a credential helper.
It refreshes on open, `g r`, saves, and its own commands, not by watching files.

## Validation and handoff

Build, headless-test, and real-terminal commands are listed in the
[development guide](development.md#terminal-smoke-tests).

The historical
[phase-9 production handoff](plans/file_picker.md#phase-9-production-verification-handoff-2026-10-07--software-complete)
records passing build/full tests and real file/content, directory, and existing
terminal checks. Its catalog counts and phase notes describe that checkpoint,
not the current command catalog. Human visual review, owner ranking examples, and
agreed live performance acceptance were recorded separately and unperformed at
that handoff; see the [picker guide](pickers.md) for integration details.

VCS manual acceptance is tracked in [the VCS checklist](testing/vcs_manual.md).
README screenshot capture and rendering details are in [images/README.md](images/README.md).
