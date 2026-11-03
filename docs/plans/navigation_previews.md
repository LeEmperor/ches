# Source previews for navigation results

## Scope

References and multiple-definition/declaration result pickers show a bounded source
window around the selected destination, with line numbers and target highlighting.
Retained buffers (including unsaved text) take precedence over disk. Previewing
does not activate/open files, change text, start language servers, or record jumps.
Enter retains existing validated navigation/history; Escape cancels.

Preview layout shares the floating picker, reserving enough result rows and hiding
the preview gracefully in tiny allocations. Loading, missing/unreadable/binary
files, truncation and stale/invalid coordinates have explicit preview states.
Positions use the server's negotiated encoding, including zero-width targets.
There is no full syntax-highlighting requirement in this phase.

## Boundaries

1. Pure navigation-preview model: bounded retained-buffer extraction and streaming
   file-window collector; display text/ranges and explicit limit states. Picker
   renderer uses safe Unicode display spans, bounds allocation before clipping,
   and never performs I/O.
2. Screen: selection generation/request/result ownership, current-buffer revision
   guards and stale-destination integration. Requests change with selection,
   document/catalog lifetime and target revision, not every render.
3. Frontend host: debounced latest-only asynchronous reads, cancellation, one
   physical read at a time, bounded bytes/lines/work and descriptor cleanup.

Retain existing navigation safeguards and avoid unbounded eager whole-file reads
for all destinations merely to browse a list. Any adjustment to destination
fingerprinting must be documented and tested against changed files/dirty buffers.

## Validation and policies

Tests cover no activation/history on preview, exact target Unicode/tab/multiline/
zero-width highlighting, stale A→B→A loads, missing/special/large files, bounded
rendering/read budgets, dirty targets, resize and existing acceptance behavior.
Full build/tests after integration. Three workers, six jobs each, cap20 total.
No personal config or Git staging/commit/push changes.

## Status

Implemented and validated. A new pure `ches_navigation_preview_model` extracts
bounded context from retained text or a streaming reader, using exact negotiated
positions for multiline/zero-width highlights. The destination picker reserves a
preview below its result list when at least eight content rows are available and
centers the target within the visible preview rows.

Screen generation guards cover selection, A→B→A, navigation origin, target lifetime
and retained revision. The frontend uses the current retained-buffer callback
after a 40 ms debounce, then disk if no retained buffer exists. One active physical
read and one latest pending request prevent queue growth. Two-second timeout
delivery cancels work, but a stalled disk thread retains its read slot until it
returns; retained-buffer previews can bypass it. UI shutdown does not wait on disk.

Limits: 8 MiB scanned/read, at most 32 lines, 4096 bytes per line and 64 KiB output.
The collected window includes three lines before the target and twenty below;
the rendered subset keeps the target visible. Limits/errors are explicit states.
No preview activation, language-server startup or history updates occur.

Eager whole-file destination hashes were replaced with device/inode/size/mtime/ctime
stamps. Regular-file stamps follow symlinks but reject special files. Disk payload
stamps and current metadata must both match original result-time metadata before
installation. This detects ordinary changes without unbounded reads but cannot
eliminate metadata-preserving rewrites or observation races.

Review fixed special-file acceptance and missing payload-stamp validation. Added
regressions cover CRLF/chunk-split UTF-16/32 targets at 8–20 rows, zero-width marks,
long-line limits, regular symlinks/special files, stale payloads and cancellation,
read failures with valid navigation, dirty text, and jump history.

Final reviewer `dune build -j 6 @all`, `dune runtest -j 6`, and `git diff --check`
passed after fixes, following the manager's full build/suite. No personal config,
staging, commits, or pushes were changed/performed.
