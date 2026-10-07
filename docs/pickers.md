# Pickers: project files, document lines and project contents

**`Space f f`** opens the project file picker; **Find project files** is also in
the command palette. Enter opens or activates a retained session buffer without
saving or reloading dirty buffers. Missing new files, unreadable files and
unsupported files fail visibly in feedback/history after focus returns; startup
new-path opening remains supported. **`Space f l`** searches
current in-memory lines, including unsaved edits, and Enter jumps to the match.
The catalog entry is **Search current document lines** (`document.lines`).
**`Space f g`** / **Search project contents** (`project.contents`) searches on-disk
case-sensitive literals. Enter validates the target's current in-memory line,
opens/activates its session buffer and reveals the location. Existing `/`, `?`, and
`Space c c` behavior is unchanged.

## What is implemented

| Foundation | Search behavior | Acceptance tested |
| --- | --- | --- |
| File picker (phases 1–6) | Discover once per opening; yielded fuzzy filtering in the shared float, preferring basenames | Session open/activation after host release and UI installation; production frontend and terminal dirty revisit, stable scope and failed opens tested |
| Document lines (phase 7) | Snapshot current in-memory text, **including unsaved edits**, with numbered duplicate/empty lines | Validated current-document jump after capture release, viewport reveal; actual frontend and terminal smoke checked |
| Project contents (phase 8) | Debounced literal search over **on-disk** bytes in shared float; excludes unsaved edits | Production session open/activation, exact raw-line/literal/range validation and display-cell jump after release; frontend and terminal dirty/stale navigation tested |

File and line matching accepts ordered subsequences, with ASCII case folding and
whitespace-separated tokens. It is not typo correction, full Unicode case folding,
or full fzf syntax. File tokens can match basename or directory context. Blank
queries list available files/lines. Owner query examples are still needed to settle
ranking. Content search is **not fuzzy or regex**: punctuation/spaces are literal;
an empty query launches no subprocess and searches nothing. Content requests are
debounced by 150 ms; obsolete runs are cancelled and cannot install results.

Picker adapters reuse palette-style text/paste editing, Backspace, Ctrl-w,
Tab/Shift-Tab (next/previous), Ctrl-n/p and Enter. Navigation clamps at the first
and last result, leaves the query unchanged and keeps the selection visible.
Pending file/line filtering or edited-but-unrequested content
queries disable acceptance; Enter is not queued. Shared host capture, focus, cursor
and interrupted paste are verified for files, lines and contents. Escape closes;
Ctrl-c displays the shared host notice. These floats require 14×5, work in zen,
and close safely below that minimum. Escape restores prior available focus without
jumping. Unrelated supporting tiles still use Tab to return focus. A changed
document invalidates line results permanently; close/reopen to refresh, never
accept stale coordinates.

## Read-only file preview

File floats prefer 175×28 on terminals at least 104 cells wide (80×28 otherwise),
centered and clamped with a one-cell margin where possible. With at least 96 content
cells, results stay left and a numbered plain-text preview appears right; narrow
terminals hide it without changing selection, keyboard focus or Enter behavior.
The prefix is bounded to 64 KiB/100 lines. Retained buffers supply current unsaved
text; other files use debounced asynchronous prefix reads without opening tabs or
starting highlighting/language servers. Loading, empty, missing, unreadable,
unsupported binary/encoding/special files and truncation are labelled explicitly.
Controls and tabs are safely mapped and wide UTF-8 clipped using editor display
cells. Resize replaces preview generations; close/replacement/deactivation/exit
clear work and screen data, and stale deliveries cannot install. Content/line
pickers and the command palette retain their existing layouts.
Phase-13 build/full tests and isolated terminal smokes pass, including native
Tab/Shift-Tab selected acceptance and dirty/missing/large previews. This is not
human visual or performance acceptance; exact evidence is in `FILE_PICKER_PLAN.md`.

## Scope, dependencies and setup

Use the repository's **OxCaml `5.2.0+ox` switch** and Jane Street
`v0.18~preview` packages, not an arbitrary stock OCaml switch. With that switch
already provisioned, install project dependencies and check the foundations:

```sh
opam install --switch=5.2.0+ox . --deps-only
rg --version
opam exec --switch=5.2.0+ox -- dune build
opam exec --switch=5.2.0+ox -- dune runtest content_picker file_picker line_picker/test palette/test screen/test
```

Async, Yojson and Base64 are declared in `dune-project` (which generates
`ches.opam`). A C compiler and `gzip` are also needed for bundled highlighting.
Install **ripgrep** using your OS package manager and put `rg` on `PATH`; version
14.1.0 was used for the final provider checks. No `fzf` or shell subprocess wrapper
is required. Missing rg/access failures produce actionable provider errors. Only
file/content providers, their tests and probes require rg, not ordinary editing,
line matching or the command palette.

The file scope is the nearest ancestor of the starting document directory
containing `.git` (file or directory) or `dune-project`, otherwise that directory.
Directory startup uses that directory; unnamed startup uses cwd. The frontend
retains and explicitly passes this root for its lifetime, even on cross-project
tab activation (including nested markers). Restart the editor to select another
scope. Diagnostic root discovery is unchanged.

Both rg providers include untracked files, respect normal ignore rules (including
parent/global rules), omit hidden components and `.git` metadata, and do not follow
directory symlinks. User rg configuration is disabled with `--no-config`. File
discovery uses NUL framing; content search uses structured JSON/base64 fields.
Raw paths remain separate from escaped display strings; an escaped spelling is
not a path alias. Discovery ordering is bytewise/deduplicated; content occurrences
retain traversal order. Capped subsets are not promised sorted prefixes.

## Bounds, freshness and coordinates

| Default | Files | In-memory lines | On-disk contents |
| --- | --- | --- | --- |
| Result cap | 50,000 candidates | First 50,000 lines | 10,000 occurrences |
| Per-record text | 4 KiB emitted path | 4 KiB line | 4 KiB path/line; 64 KiB JSON record |
| Retained string budget | 8 MiB candidate path strings | 8 MiB copied line text | 8 MiB hit path/text strings |
| Stdout / timeout | 32 MiB / 30 seconds | No child process | 32 MiB / 10 seconds after launch |

Caps are visibly labelled **TRUNCATED** by headless tiles, even when nothing fits;
errors/partial/no-match/loading states are distinct. Line preparation stops at the
first exceeded cap. Providers kill and reap children on caps, timeout or cancel;
one reused provider has at most one child and one queued batch. `finished` confirms
cleanup, not consumption of terminal status: hosts must still poll. Cancellation
retains the provider's bounded last snapshot until refresh or provider disposal;
closed sessions drop their results/cache. Do not retain historical snapshots.

File/content requests reject stale runs/roots (content also checks query). Line
sessions capture document identity, revision and immutable text identity; changed
documents invalidate them permanently, requiring reopen. Line acceptance checks
freshness again after releasing capture.

Matcher highlights are UTF-8 **byte offsets**, not navigation columns. Line
acceptance converts raw match bytes using the editor's width table into one-based
display cells, accounting for TABs/wide/control glyphs; combining marks map to the
preceding visible glyph/first cell. Content intents retain one-based lines and
zero-based byte start/end (end exclusive); the UI labels its printed column as
one-based **BYTES, not cells**. Production acceptance validates the whole raw line
(including final LF), literal and UTF-8 byte boundaries before tab activation,
then converts using the opened editor's display-cell API. Dirty buffers are never
reloaded: edits elsewhere are allowed, changed searched lines fail visibly. New
missing/unsupported files also fail, preserving the previous document and restored
focus. Only LF/valid UTF-8 text is supported; CRLF is not normalized. Reopen search
to refresh stale results. See [content policy](../content_picker/README.md#location-validation-and-dirtyfailure-policy).

Work uses bounded record turns (suggested 128), not hard time bounds. Prepared
arrays, maps, old/in-flight results, JSON decoding and rendering add memory beyond
string caps. DP matching, GC and O(results) publication/navigation can be costly.
The live host must yield and schedule work between input/redraws, neither drain
inside key callbacks nor limit ranking to one turn per frame.

## Current verification and remaining acceptance

Phases 1–8 and phase-9 software verification are complete. Historical floating,
buffer and content-opening blockers are superseded by the production handoffs in
[`FILE_PICKER_PLAN.md`](../FILE_PICKER_PLAN.md#phase-9-production-verification-handoff-2026-10-07--software-complete).
The build and forced full suite pass; no unrelated snapshots were promoted here.
Production frontend tests use real rg and session opening, not just fake consumers.
The catalog currently has **54 commands**, including all three picker entries.

Run the isolated terminal checks after building:

```sh
python3 scripts/picker_smoke.py
python3 scripts/directory_workspace_smoke.py
TMPDIR=/tmp/opencode bash scripts/smoke.sh
```

The file/content smoke uses a private tmux socket and fixtures under
`/tmp/opencode`, never repository files. It checks real binding/catalog activation,
query/selection/cancel/accept, dirty revisits, missing/stale failures, Unicode/TAB
navigation, undo, zen restoration, minimum/tiny/resized floats, interrupted paste,
unchanged disk bytes and terminal-mode restoration. Captures stay in the printed
fixture's hidden `.captures` directory so they cannot become search results.
Headless lifecycle tests additionally reject stale provider turns and acceptance
after deactivation and assert child cleanup/reaping.

**Human visual validation remains unperformed for all pickers** (styles, cursor
shape, flicker and perceived usability). Automated terminal captures are not
human sign-off. Owner ranking examples and live performance acceptance also remain
separate; no new latency, p99 or peak-RSS guarantee is claimed.

For local headless measurements, see [file/query/discovery probes](../file_picker/bench/README.md)
and [line probe](../line_picker/README.md#reproducible-scale-probe). They do not
establish live input-to-screen latency, p99, peak RSS, or an agreed performance
budget. An owner target dataset, ranking examples and responsiveness budget remain
open requirements before release claims.
