# File, line, and content pickers: foundations, not shipped features

The editor still edits **one document per session**. These libraries and screen
adapters are tested headlessly, but none is connected to the live tile host.
`Space f f` is a planned Normal-mode binding, **not available**. No line/content
binding or command-palette entry is installed. Installing ripgrep does not enable
these commands. Existing `/`, `?`, and `Space c c` behavior is unchanged.

## What is implemented

| Foundation | Search behavior | Acceptance tested |
| --- | --- | --- |
| File picker (phases 1–4) | Discover once per opening; fuzzy-filter relative paths, preferring basenames | Typed raw-path intent to a fake consumer after release; no file opened |
| Document lines (phase 7, partial) | Snapshot current in-memory text, **including unsaved edits**, with numbered duplicate/empty lines | Real current-document `Controller.jump` result in headless tests; no live viewport/focus integration |
| Project contents (phase 8, partial) | Case-sensitive literal substring search over **on-disk** bytes; excludes unsaved edits | Typed open-at-location intent to a fake consumer; no file opened or cross-file jump |

File and line matching accepts ordered subsequences, with ASCII case folding and
whitespace-separated tokens. It is not typo correction, full Unicode case folding,
or full fzf syntax. File tokens can match basename or directory context. Blank
queries list available files/lines. Owner query examples are still needed to settle
ranking. Content search is **not fuzzy or regex**: punctuation/spaces are literal;
an empty query launches no subprocess and searches nothing. Content requests are
debounced by 150 ms; obsolete runs are cancelled and cannot install results.

Headless adapters reuse palette-style text/paste editing, Backspace, Ctrl-w,
Ctrl-n/p and Enter. Pending file/line filtering or edited-but-unrequested content
queries disable acceptance; Enter is not queued. Host-owned Escape/Tab/Ctrl-c,
capture, focus and interrupted-paste handling still need live integration.

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

## Why live acceptance is unavailable

1. **Phase 5:** shared floating compositor and command-palette migration are not
   implemented. `Frame` still composes tiled panes and the palette occupies the
   bottom band/rejects zen. Real focus/paste/cursor ownership, minimum three
   content rows, resize, late-event isolation and yielded scheduling are unverified.
2. **Phase 6:** the actual multi-buffer open/activate-existing API is absent.
   Startup `Controller.open_file` can create an empty document on a missing path
   and is not a safe picker adapter. Dirty-buffer/undo retention, path identity,
   failure/focus policy and cross-document diagnostic isolation belong to buffers.
3. **Phase 7:** current-document jumping does not require buffers, but still needs
   the floating host, controller-change invalidation and viewport reveal, plus a
   nonconflicting binding and live acceptance checks.
4. **Phase 8:** also needs open-at-location and opened-content/dirty-buffer
   validation before converting byte coordinates or handling changed/missing files.

The achievable independent phase-9 checks are recorded in
[`FILE_PICKER_PLAN.md`](../FILE_PICKER_PLAN.md#phase-9-implementation-and-handoff-2026-10-07--partial).
The forced full suite currently reports seven unpromoted snapshot mismatches in
four `ui/test/test_editor_view.ml` tests (default-visible tile geometry/cursors).
No picker terminal smoke or human visual acceptance has been performed: there is
no live integration to exercise. Existing smoke coverage is not picker acceptance.

For local headless measurements, see [file/query/discovery probes](../file_picker/bench/README.md)
and [line probe](../line_picker/README.md#reproducible-scale-probe). They do not
establish live input-to-screen latency, p99, peak RSS, or an agreed performance
budget. An owner target dataset, ranking examples and responsiveness budget remain
open requirements before release claims.
