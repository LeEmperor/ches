# Project on-disk literal search — phase 8 PARTIAL

This is an independent, headless provider/model/tile, not a shipped editor search
binding. Shared floating composition/host integration and real multi-buffer
open-at-location are unavailable. No registry, compositor, buffer manager or
no-op binding is added.

## Scope and semantics

- Requires `rg` on PATH (or an explicitly configured executable). The provider
  reports actionable spawn errors; it never invokes a shell.
- Host retains an explicit absolute project root. Reuse
  `Ches_file_discovery.Project_root.find`: nearest `.git` file/directory or
  `dune-project`, fallback to starting document directory. Do not silently move
  root when activating another same-project file or change diagnostics policy.
- Shares `Ches_file_picker.Scope` with file discovery: `--no-config`, normal
  ignore rules, untracked included, hidden/`.git` omitted, no directory-symlink
  following. Global/parent ignore rules remain ripgrep's normal defaults.
- `rg --json --fixed-strings --case-sensitive --line-number --color never --
  QUERY .` in the explicit root. Literal substring, including spaces and regex
  punctuation; not fuzzy, regex or smart-case. Empty means **no child/no search**;
  whitespace-only is a real literal. No multiline, NUL, CR or LF queries.
  No binary-search override: ripgrep's normal binary detection applies.
- Searches current **on-disk** bytes, never dirty buffers. A row is one occurrence,
  not one file/line. Multiple occurrences on a line are separate rows.
- JSON path/text fields accept both UTF-8 `text` and base64 `bytes`. Raw path and
  raw line (including line ending/invalid bytes) are retained separately from safe
  escaped display. No parsing of colon-delimited rows. Only leading `./` stripped.
  Parser checks positive lines, in-range nonempty offsets and literal agreement;
  malformed records fail visibly with partial results retained.

## Host/lifecycle

Use `Ches_content_search.Provider` on the Async scheduler. Reuse one provider.
`start ~root ~query` validates before disturbing an active run, assigns a fresh
run/root/query identity and immediately clears prior hits. It cancels the old
run, waits for its descriptor closure/reaping, debounces 150ms, and then launches.
Repeated starts coalesce: obsolete debounced runs never launch. Cancel immediately
kills the child/closes delivery; cancellation during creation is handled when
the child appears. At most one child and one queued batch per provider.

`finished` acknowledges cleanup/reaping, **not** consumption of terminal status.
Poll `~max_batches` in yielded bounded turns. Results retain traversal order;
the capped subset is not a promised sorted prefix. Do not keep historical snapshots.
Terminal states are separate from batch pushback so timeout still reaps when the
host stops polling. Old pipes cannot update a replacement run.
Cancellation retains the provider's bounded last snapshot/hit list for inspection
until refresh or provider disposal; closing the model separately drops its hits.
Hosts must not retain old snapshots/runs after cleanup.

For `Content_picker_tile`/`Model`, edits immediately disable old-result acceptance.
Edited literals are capped at a complete UTF-8 boundary within 4KiB; shortening
is disclosed by a `QUERY TRUNCATED` status until the next nontruncating edit.
Start the changed literal promptly (provider owns debounce), call `expect` with
its request, then `install` snapshots: exact run/root/query equality is required.
Never call `expect` with an obsolete request. Installation preserves selection by
raw path/line/start/end, falling back to first/none when missing. Enter with no
selection or edited-but-not-requested query is inert, not queued. Partial matches
may be accepted. Accept/cancel closes exactly once, drops retained hits, releases
capture/provider, then delivers one typed intent to the injected consumer.

Future live host owns floating placement (at least query/status/result: three
content rows), focus/cursor, resize, cancellation, paste isolation and yielded
polling/redraw. Errors/truncation are in status row **and** footer. Tiny headless
allocations safely clip; a future host must enforce minimum geometry. No live host
or terminal/human visual testing is claimed here.

## Location contract — not a navigation implementation

Internal `line` is one-based; `start_byte`/`end_byte` are zero-based raw byte offsets,
end exclusive. UI prints byte column `start_byte + 1` and explicitly labels BYTES,
not display cells. A typed intent retains raw path, line, byte range, raw expected
line and literal. It must **not** be passed straight to `Controller.jump`.

The future actual buffer adapter must open/activate an **existing** file without
losing dirty buffers, fail on disappearance, validate the expected line/literal
against the opened current contents (also account for dirty buffers and encoding),
then convert byte boundaries with that document's navigation API. If changed,
fail visibly or rerun search rather than jumping blindly. That adapter/API is a
dependency, not a fake production implementation.

## Bounds and caveats

Defaults: 10,000 occurrences, 4KiB raw line/path, 64KiB JSON record, 8MiB retained
string payload (paths/display/root + raw text per hit, conservatively counted),
32MiB stdout, batches of 128, 10 seconds after launch including backpressure.
Stderr drains in 4KiB chunks retaining an 8KiB prefix, safely escaped on failure.
Every count/path/line/payload/record/output cap stops/kills/reaps with visible
`Complete { truncated = true }`, even if no hits fit. Timeout/read/JSON/process
failure is `Failed` and retains valid partial hits. Exit 1 is normal no-match.

Limits bound retained strings/records, not total process RSS: list/map-free model
overhead, queued/transient batches, JSON/base64 decoding and escaped rendering add
overhead. JSON parse work is bounded by record bytes; workers yield on record groups
and stderr chunks. Snapshot reversal, selection installation/navigation and fitting
are O(hits), not strict time bounds. Debounce does not promise input-to-screen
latency; no responsiveness target/p99/live performance claim is made.

## Checks

See `RESULTS.md` for commands/outcomes and `HANDOFF.md` for done/pending work.
