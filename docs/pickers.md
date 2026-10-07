# Pickers: live document lines and file/content foundations

The editor still edits **one document per session**. The file picker is integrated
with the shared floating host and Async/Bonsai scheduling through an explicit
test-consumer assembly boundary; it does not open files. **`Space f l`** searches
current in-memory lines, including unsaved edits, and Enter jumps to the match.
The catalog entry is **Search current document lines** (`document.lines`).
`Space f f` is reserved, **not available**. Content search has shared floating
host/runtime/frontend test integration, but no live activation or real opener.
Installing ripgrep does not enable file/content opening. Existing `/`, `?`, and
`Space c c` behavior is unchanged.

## What is implemented

| Foundation | Search behavior | Acceptance tested |
| --- | --- | --- |
| File picker (phases 1–5) | Discover once per opening; yielded fuzzy filtering in the shared float, preferring basenames | Raw-path intent to an injected consumer after host release; actual provider/frontend integration tested; no file opened |
| Document lines (phase 7) | Snapshot current in-memory text, **including unsaved edits**, with numbered duplicate/empty lines | Validated current-document jump after capture release, viewport reveal; actual frontend and terminal smoke checked |
| Project contents (phase 8, partial) | Debounced literal search over **on-disk** bytes in shared float; excludes unsaved edits | Typed byte-location intent after release to an injected consumer; real provider/frontend and interrupted resize/paste tested; no file opened or cross-file jump |

File and line matching accepts ordered subsequences, with ASCII case folding and
whitespace-separated tokens. It is not typo correction, full Unicode case folding,
or full fzf syntax. File tokens can match basename or directory context. Blank
queries list available files/lines. Owner query examples are still needed to settle
ranking. Content search is **not fuzzy or regex**: punctuation/spaces are literal;
an empty query launches no subprocess and searches nothing. Content requests are
debounced by 150 ms; obsolete runs are cancelled and cannot install results.

Picker adapters reuse palette-style text/paste editing, Backspace, Ctrl-w,
Ctrl-n/p and Enter. Pending file/line filtering or edited-but-unrequested content
queries disable acceptance; Enter is not queued. Shared host capture, focus, cursor
and interrupted paste are verified for files, lines and contents. Escape/Tab close;
Ctrl-c displays the shared host notice. These floats require 14×5, work in zen,
and close safely below that minimum. Escape
or Tab restores prior available focus without jumping. A changed document invalidates
line results permanently; close/reopen to refresh, never accept stale coordinates.

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

The proposed host scope is the nearest ancestor of the starting document directory
containing `.git` (file or directory) or `dune-project`, otherwise that directory.
Hosts must retain and explicitly pass this root rather than silently move it on
same-project file activation. Diagnostic root discovery is unchanged.

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
one-based **BYTES, not cells**. The future consumer must validate opened contents
and convert coordinates, never pass raw bytes straight to `Controller.jump`.

Work uses bounded record turns (suggested 128), not hard time bounds. Prepared
arrays, maps, old/in-flight results, JSON decoding and rendering add memory beyond
string caps. DP matching, GC and O(results) publication/navigation can be costly.
The live host must yield and schedule work between input/redraws, neither drain
inside key callbacks nor limit ranking to one turn per frame.

## Remaining file/content integration blockers

1. **Phase 5 software integration is complete:** shared floating composition,
   focus/paste/cursor, three-row content minimum, resize, late-event isolation and
   yielded scheduling have automated host/provider/frontend checks. Its consumer
   is explicitly injected for tests; there is no shipped file-opening command.
2. **Phase 6:** the actual multi-buffer open/activate-existing API is absent.
   Startup `Controller.open_file` can create an empty document on a missing path
   and is not a safe picker adapter. Dirty-buffer/undo retention, path identity,
   failure/focus policy and cross-document diagnostic isolation belong to buffers.
3. **Phase 7 software integration is complete:** current-document jumping does not
   require buffers. Shared floating host, invalidation, viewport reveal, live binding
   and catalog dispatch have automated integration/frontend/terminal checks. This
   does not claim human visual acceptance or a measured responsiveness guarantee.
4. **Phase 8 remains PARTIAL:** shared floating/runtime test integration is implemented,
   including debounce/cancellation/reaping, one batch per yielded poll and stale
   query/session isolation. Actual open-at-location and opened-content/dirty-buffer
   validation remain required before converting bytes or handling changed/missing
   files. Live binding/catalog activation waits for that API.

The final post-integration phase-9 review, exact future API integration checklist
and observed checks are recorded in
[`FILE_PICKER_PLAN.md`](../FILE_PICKER_PLAN.md#phase-9-final-post-integration-review-and-handoff-2026-10-07--partial).
The forced full suite currently reports seven unpromoted snapshot mismatches in
four `ui/test/test_editor_view.ml` tests (default-visible tile geometry/cursors).
File-picker terminal smoke/human visual acceptance has not been performed. The
phase-5 shared-palette terminal regression smoke passes; that is not file-opening
acceptance. The actual file-picker Bonsai frontend is exercised headlessly with
real rg and an explicit consumer, without exposing a no-op user command. Content's
actual frontend likewise uses real rg and typed test consumption; content-specific
terminal smoke/human visual review remains unperformed.

Final review fixed frontend file-session teardown: deactivation now drops retained
filtering work/cache/results as well as cancelling discovery, with a Bonsai lifecycle
regression rejecting late work and acceptance. The owner awaits `Runtime.finished`
for process cleanup. Final build and live `Space f l` terminal smoke pass; the full
forced suite has only the documented UI snapshot failures above. **Human visual
validation is still unperformed for all pickers.** File/content tests deliver intents
to injected consumers; they do not demonstrate real cross-file opening/navigation.

For local headless measurements, see [file/query/discovery probes](../file_picker/bench/README.md)
and [line probe](../line_picker/README.md#reproducible-scale-probe). They do not
establish live input-to-screen latency, p99, peak RSS, or an agreed performance
budget. An owner target dataset, ranking examples and responsiveness budget remain
open requirements before release claims.
