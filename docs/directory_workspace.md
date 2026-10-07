# Directory workspace reference

Ches retains file tabs and visited directory buffers within one session. See the
[editor reference](editor_reference.md) for modal text editing and other tiles.

**Removing an existing identity row and saving permanently deletes its backing
file/link or empty directory. There is no trash, confirmation dialog or filesystem
undo.** Directory text is a proposed filesystem plan, not a file to serialize.

## Navigation, tabs and opening

`ches .` starts a major directory buffer with zero file tabs. `Enter` on a file
opens/activates its persistent tab; on a directory (including a directory symlink)
it navigates. `-` goes to the lexical parent and selects the child just left.
`Space o` from a file opens its parent with that file selected; from a directory it
returns to the remembered live file, else the active file tab. With neither it
stays put. Directories never become file tabs. Dotfiles are included; entries sort
by raw byte name without directory grouping. Cached revisits do not reread disk:
`Space r` refreshes a clean listing, refusing dirty edits. Directory `:e!` refuses;
undo pending edits before refresh, or force quit explicitly to discard memory intent.

| Keys | Mode | Action |
| --- | --- | --- |
| `Space b n` / `Space b p` | Normal | Next / previous file tab, wrapping |
| `Space b c` / `Space b C` | Normal | Close / force-close and discard tab |
| `Space b r` | Normal | Exclusively recreate a missing file path |
| `Enter` | Normal directory | Open cursor entry, ignoring unrelated marks |
| `Enter` | Visual directory | Open intersected entry rows |
| `Space m m` | Normal/Visual directory | Toggle cursor entry mark |
| `Space m s` / `Space m u` | Normal/Visual directory | Mark / unmark selection (cursor row outside Visual) |
| `Space m c` / `Space m o` | Normal/Visual directory | Clear directory marks / open marked files |
| `Space w` | Normal | Save focused file / apply focused directory plan |
| `Space q` / `Space Q` | Normal | Guarded quit / explicit discard quit |

Files keep independent text, undo, cursor, highlight runtime and viewport; the
unnamed register/clipboard are shared. Tabs show for two or more files when there
is room, hide in zen, disambiguate equal basenames, show `*` for edits and
`[missing]` for deleted resources. Overflow retains the active ordinal and uses
`<`/`>` for hidden neighbors. Close chooses the next tab at the old index, else
the preceding last tab. Closing the last file shows the remembered directory,
else startup directory. Dirty/missing tabs require save/recovery or `Space b C`.
Close is not application exit. Quit checks inactive files and hidden dirty directories.

Visual batches support characterwise, linewise and blockwise selections. Visual
and marked batches use current text order, deduplicate resources, skip directories
and special kinds, continue after failed opens, and activate the first success.
Only open-marked clears successful marks; failed/skipped marks remain. Ordinary
Enter ignores unrelated marks. Marks are directory-local entry-ID decorations,
outside text/undo/dirty state. Removing a row leaves its mark dormant until undo
or commit. Invalid identity text refuses row actions. Fresh/copy rows require save
before opening/marking; renamed rows open their original backing path until apply.
Opening never implicitly saves. The clipboard contains names only in the default
hidden mode, never protected IDs, headers/gutters/marks.

Resource identity is lexical, absolute, case-sensitive path normalization: repeated
slashes, `.` and `..` collapse, without realpath/inode deduplication. `link/..` thus
means the lexical parent, not OS symlink traversal. Separate symlink/hard-link
aliases can be separate buffers, without save conflict detection. File open/save
through a symlink follows its target; directory-entry mutations act on the link.

## Placement and focus

| Keys (Normal/Visual) | Action |
| --- | --- |
| `Space d m` | Present directory in major editor area, keeping file tabs underneath |
| `Space d s` | Show/request left side browser |
| `Space d h` | Hide browser without discarding edits or marks |
| `Space d f` | Toggle browser/editor focus |
| `Space d +` / `Space d -` | Grow/shrink preferred side width by four columns |

Side Normal/Visual `Tab` returns to the editor; Insert `Tab` inserts soft-tab spaces.
Side file opening keeps the browser
present and focuses the opened file. Preferred outer width starts at 32 and stays
within 16–500. Side layout needs at least 33 columns and four rows, leaving at least
16 editor columns and a one-cell gap. Zen or insufficient space suppresses the side
without discarding its request. Focus returns to an available file; with no files,
the directory remains a reachable major fallback. Expanding restores the side
without stealing file focus. Hiding/moving preserves pending text, selection,
scroll (fitted to the viewport), marks and return target. There is one editor group
and one directory presentation, not simultaneous views.

## Identity editing and byte names

IDs are **always hidden by default**, including selected rows and Insert/Visual
editing, in both major and side presentations. Existing editable rows look like:

```text
main.ml
src/
```

Edit the name as ordinary text to rename, retaining the existing directory `/`
suffix. Identity is protected metadata in immutable text/undo snapshots, not an
editable prefix or a row-number guess. Replacing an entire name (including Visual
line change) retains identity; an empty existing name is invalid until filled or
its whole row deleted with `dd`/Visual line delete. IDs belong to this directory's
baseline, not row numbers. Whole-row
reordering has no disk effect. Bare rows create empty immediate-child files; a
bare name ending in `/` creates a directory. Parents are never implicitly created.
Fresh blank rows are ignored. Existing kinds cannot change; FIFO/socket/device entries
are visible but read-only. Malformed, unknown or duplicate IDs invalidate the whole
snapshot. Linewise yank/delete/paste carries protected identity within the same
directory; `ddp` reorders without disk changes. Whole-name characterwise yanks also
retain identity internally. Pasting protected rows into another directory is
refused; pasting into a file or the system clipboard inserts names only. Pasted
text from the system clipboard has no identity and proposes fresh entries.
Block yanks covering complete protected names cannot be pasted into directory
buffers: use linewise operations instead. Partial block/characterwise fragments
remain ordinary name text, not filesystem-copy instructions.

Inserting a newline inside a name keeps identity on the left fragment and creates
a fresh right row; inserting a whole line at column zero keeps the original
identity with the original row on the right. Joining protected existing rows, or
replacing several protected rows with one name, is ambiguous and refuses the whole
plan: undo and use whole-row operations instead. Undo/redo restores text and IDs
together. Editing never auto-reveals IDs.

### Backend configuration

There is no runtime configuration-file system. Code callers can explicitly select
legacy exposed tokens with `Session.create ~directory_config:Directory_buffer.Config.Exposed`,
or `Ui_state.create ~directory_config:Directory_buffer.Config.Exposed`; direct loads
accept `Directory_buffer.load ~config:Directory_buffer.Config.Exposed`. The default
is `Directory_buffer.Config.Hidden`, retained across navigation, refresh and apply.
In exposed mode rows are `@ches[ID]<TAB>NAME` (literal TAB), and IDs/separators are
editable legacy text. Keep them intact to rename; Insert-mode Tab inserts spaces,
so use bracketed paste for a literal TAB. This backend option is not a CLI flag.

Names use lossless printable ASCII byte encoding, even for Unicode/invalid UTF-8
names. Bytes below 32 or at least 127, backslash, `@`, and leading/trailing spaces
in **each path component** use canonical uppercase `\xHH`: TAB `\x09`, newline
`\x0A`, backslash `\x5C`, `@` `\x40`, byte FF `\xFF`, edge space `\x20`.
Internal spaces stay literal. No trimming, shell quoting, glob, `~` or variable
expansion occurs. Empty names, NUL, encoded slash and final `.`/`..` are invalid.
All legal Unix filename bytes round-trip; file *contents* still require UTF-8/LF.

In exposed mode tokens are protected **by validation, not by blocking edits**. Removing a whole
token can mean deletion of the original plus creation of a fresh entry, not rename.
Exchanging valid tokens changes which identity is renamed. An invalid snapshot
executes zero operations; a valid but destructive edit is not inferred away.

## Copies, destinations and permanent deletion

Omitting an existing row requests permanent unlink of its file/symlink, or rmdir
of its **empty** directory on Save. Nonempty deletion refuses the entire preflight,
including other operations. There is no recursive delete or trash fallback. A
directory symlink is unlinked without touching its target.

Duplicated existing rows are invalid, not empty-file creation requests. In hidden
mode, yank/paste a whole row, prefix its visible name with `@copy ` (one space),
and choose a distinct destination, retaining the kind suffix:

```text
main.ml
@copy ../backup/main.ml
```

The copy marker uses the pasted row's protected source identity; typing it on a
fresh row is invalid. Prefixing the only original row converts it to a copy and
requests deletion of the source as well, so normally keep the original row.
After a partial apply, pending copies may carry the copy identity behind the
scenes without the marker. In exposed mode, change the copied token to
`@copy[ID]`, retaining TAB/kind (the notation `<TAB>` means a literal TAB):

```text
@ches[1]<TAB>main.ml
@copy[1]<TAB>../backup/main.ml
```

The ID refers to this baseline's original backing entry, not another directory's
ID or unsaved tab text. Copies read **disk**. Multiple explicit copies are allowed.
Keeping the original row keeps the source; omitting it means copy **and permanent
delete**. Files, recursive directory trees and symlinks are supported; special
kinds anywhere in a copied tree refuse preflight. Symlinks copy link bytes without
following targets or rewriting relative links (which may resolve differently at
the destination). Copies preserve file/directory rwx bits, not set-ID/sticky bits,
owner, timestamps, ACLs, xattrs, sparseness or hard-link relationships.

Existing/copy rows accept relative (`../other/name`, `sub/name`) or absolute
(`/absolute/name`) lexical destinations. Literal `/` separates individually escaped
components; intermediate `.`/`..` are allowed. Existing/copy directories retain a
final `/`; symlinks do not acquire it. Fresh rows still create immediate children only.
Parents must exist. Destination occupants, including dangling links, are never
implicitly replaced. Moves use Linux no-overwrite rename and may **not cross
devices**; there is no copy/delete fallback. Copies may cross devices.

Swaps/cycles within a listing use staged renames. Destinations inside their source
directory, including detectable symlink-parent aliases, are rejected. Destinations
overlapping moved/deleted parents require separate saves. Destinations under other
dirty cached directories are blocked until those edits are saved/undone. Dirty
source descendants follow a directory move, retaining pending text/history. Open
files/descendants, resource indexes, tab labels and diagnostic lifetimes follow
actual completed moves.

## Save, partial failure and recovery

`Space w` / palette **Save buffer** applies the focused directory's validated
plan **directly**, with a readable summary in feedback/history and pending/invalid
state in its header. File focus in a side layout saves only the file. Application
save-all visits dirty files/directories in buffer-ID order, continues on failures
and reports each result; no default key or palette action exposes that API.
There is also no interactive open-path/save-as prompt.

Whole-plan preflight and per-mutation rechecks detect source/parent changes as far
as practical. Linux `renameat2(RENAME_NOREPLACE)` enforces destination no-overwrite;
unsupported kernels/filesystems/platforms fail visibly, without unsafe fallback.
This is **not** a lock, transaction or consistent tree snapshot. Source/parent
replacement after the last check, indistinguishable inode/stat reuse and recursive
copy changes remain race limits. File text saves are still synchronous/in-place,
without atomic replacement or external-content conflict detection.

Partial failure leaves completed operations on disk. Feedback reports completed
mutations, actual backing paths and remaining intent. Buffers rebase to actual
outcomes; subsequent Save retries only unresolved intent, not successful creates,
copies or final renames. Incomplete moves can leave `.ches-stage-*` names, which
become rows/open buffers' actual backing paths. Copies publish from a private
`.ches-copy-*` tree at the destination; ordinary failure cleans its owned tree.
An externally relocated/replaced parent can leave that private tree behind:
cleanup refuses to delete an unrelated replacement at the same lexical path.
Crashes can also leave private/staging paths; intent is not persisted across
restarts. Do not remove staging paths needed by a running retry. Force close/quit
discards remaining **memory intent**, not completed disk changes.

Successful apply refreshes the baseline and resets directory text undo history.
Partial progress also resets old undo, keeping unresolved edits dirty. `u`/`Ctrl-r`
undo pending text **before save**, never filesystem changes. Zero-progress preflight
failure retains text/history. A post-apply refresh failure retains the known actual
baseline and reports explicit `Space r` guidance.

Deleted open files retain text, dirty state, cursor and undo, with `[missing]` in
tabs/status. Routine save/save-all refuses resurrection; close/quit require explicit
discard even for clean retained text. `Space b r` / **Recreate missing path** creates
the missing path exclusively from retained text, refusing any reappeared occupant
and never creating parents. `Session.save_as` is an exclusive application recovery
API, not a user-facing prompt; failed exclusive writes can leave a partial new file.
External deletions are detected when the controller checks its backing path, not
by a watcher. Visited directories stay cached for the session without eviction.

## Validation

After `dune build` and `dune runtest`, run:

```sh
python3 scripts/directory_workspace_smoke.py
TMPDIR=/tmp/opencode scripts/smoke.sh
```

The directory runner executes isolated PTY scenarios for navigation/batch opening,
placement/focus, dirty guards, copy/delete/recovery/move and save reconciliation.
Fixtures/captures stay under `/tmp/opencode`; it does not mutate repository files.
Fault-injected retries, destination races and runtime lifetimes have durable
headless coverage in `test/`, `screen/test/` and `source/test/`. These automated
checks are not human sign-off of colors, cursor shape or flicker.
