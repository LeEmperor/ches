# Fuzzy file picker

Status: phases 1–4 implemented; phases 7–8 PARTIAL (independent headless portions);
phases 5–6 blocked and phase 9 PARTIAL (achievable independent review/checks done;
live release acceptance blocked). Phase-3 ranking remains
provisional pending owner query examples; no live performance claim. Scoped on 2026-10-07.

## Goal

Provide an fzf-lua-style project file picker on `Space f f`: type loose filename
and directory fragments, select a highlighted result, and open it in the editor.
Use the shared floating-tile system and reuse the command palette's matching and
interaction foundations. Follow with fuzzy search over the current document's
lines, then project-wide content search.

A separate feature branch is implementing tabs and multiple open buffers. That
feature owns document opening, buffer retention, dirty state, and tab activation.
This plan must integrate with it rather than introduce a competing single-buffer
replacement flow or a save-before-switch restriction.

## Mandatory agent / AI constraints

- Agents and AI may edit working-tree files and run appropriate local checks.
- Agents and AI must make **no mutative Git changes**: no `git add`, commits,
  merges, rebases, cherry-picks, resets, branch changes, worktree changes, tags,
  pushes, or other Git/index/history/ref mutations.
- Read-only Git inspection, such as status, diff, log, and show, is permitted.
- Agents and AI must perform **no GitHub mutations or publication**, including
  opening or changing pull requests, issues, comments, reviews, releases, or
  anything else attributable to their activity on GitHub. Do not add AI author
  or co-author attribution. Git operations and publication belong to the human.
- Preserve unrelated work. Do not reconcile feature branches by merging them;
  report missing dependencies and leave integration to the human.
- Each phase handoff must identify changed files, checks run and their outcomes,
  unresolved decisions, and remaining dependencies. Do not claim a phase is
  complete when only its independent portion is implemented.

## Starting point

At initial inspection, this worktree (`bpurtell/files`) and local `oxcaml` had
identical file contents. Reinspect the current state before implementation:
other feature work may have progressed.

- `palette/fuzzy.ml` / `.mli`: pure, command-independent fuzzy matching, weighted
  fields, whitespace-separated tokens, and byte-offset match positions.
- `palette/palette.ml`: query editing, paste sanitization, selection, and
  command-specific acceptance.
- `screen/palette_tile.ml`: query row, scrolling results, matched-text styling,
  and cursor placement.
- `tile/host.ml`: focus, input capture, paste ownership, and cursor ownership.
- `screen/floating.ml`: floating geometry. At inspection, overlay composition
  and command-palette migration were pending; see `FLOATING_TILES_PLAN.md`.
- `source/workspace_root.ml`: existing root discovery recognizes `dune-project`.
- `app/controller.mli`: startup `open_file` and current-document `jump`; it does
  not yet expose the multi-buffer opening/activation operation this picker needs.
- `source/` and `ui/editor_view.ml`: asynchronous diagnostic event delivery offers
  useful patterns, but picker discovery must not masquerade as diagnostics.

## Dependency labels

Every phase below explicitly states whether it can be completed **without the
multiple-buffers feature**. “Yes” means its deliverable and verification can be
completed independently, not that cross-file opening is already usable.

Floating tiles are a separate dependency. Avoid duplicating their compositor or
placement work. Pure picker logic and providers can proceed before floats land.

## Intended first-release behavior

- Normal-mode `Space f f` opens a floating file picker.
- Search scope is the current project, with relative paths shown in results and
  the root made visible in the picker UI.
- Include untracked files, respect ignore rules, and exclude `.git` metadata.
  Initial policy: omit hidden files; an explicit include-hidden mode can follow.
- Opening another file within the same project does not move the search root.
- Discover files once per picker opening, asynchronously; filter the discovered
  candidates as the query changes rather than rerunning traversal per keystroke.
- Support paste, word deletion, selection movement, Enter, and cancellation using
  the command palette's established conventions.
- Display full relative paths where possible, favor basename matches, and keep
  enough directory context to distinguish identically named files.
- Escape restores prior focus without changing document contents or viewport.
- Enter requests opening/activating the selected path through the multi-buffer
  system. Existing unsaved buffers remain governed by that system.
- Preview panes, persistent indexes, file watchers, and full fzf query syntax are
  follow-up work rather than requirements for the first release.

## Phase 1 — Define picker data and integration contracts

**Possible without multiple buffers: YES.**
**Floating dependency: none.**

Define a small pure model for file candidates, discovery state, query results,
selection identity, and acceptance requests. Keep filesystem paths separate from
display strings; display sanitization must not change the path opened.

Acceptance should produce data representing an open-path intent, not directly
replace a controller. Future search results can carry an optional line/column;
define coordinate conventions explicitly when adding location support.

Identify the contract expected from the tabs/buffers branch:

- Open an existing path or activate its existing buffer/tab.
- Define path identity and duplicate-opening policy in that subsystem.
- Preserve dirty buffers, undo histories, and existing session state.
- Report open failures without destroying the current buffer.
- Support location navigation after opening when content search is integrated.
- Own highlighting, diagnostics, and late-event isolation across documents.

Use a fake acceptance consumer in headless tests until the real API exists. Do
not implement a second buffer manager or guess an unfinished branch's API.

**Done when:** typed candidates and open intents are testable independently of
the screen and controller, and the cross-branch integration requirements are
explicit.

### Phase 1 implementation and handoff (2026-10-07)

- Added `file_picker/dune`, `file_picker/model.ml`, and `file_picker/model.mli`:
  the independent `Ches_file_picker.Model` library depends only on Core. Candidate
  construction validates absolute roots and normalized relative paths lexically,
  preserves original path bytes, and produces separate escaped single-line UTF-8
  display text. It performs no filesystem IO or canonicalization. Candidate identity
  is the exact joined absolute path within a picker; buffer identity/deduplication
  remains the responsibility of the tabs/buffers subsystem.
- Contracts cover explicit discovery requests with run identities; loading,
  partial, completed (including empty/truncated), failed, and cancelled snapshots;
  ranked query results with display-string byte offsets; and stable selection by
  candidate identity. Installing results preserves selection if present, otherwise
  selects the first result or none. Discovery snapshots and query results are
  producer-owned data, not an implemented discovery/event or matching engine.
- Acceptance returns an optional typed `{ token; path }` open-existing-path intent.
  The host must close/release input capture before delivering it exactly once;
  cancellation discards the model. No-selection acceptance returns no request.
  This is deliberately not a controller replacement or buffer-opening API.
  Location support is deferred: line numbering and column units must be specified
  against the actual navigation API before adding fields; display byte offsets
  are not navigation columns.
- The future real acceptance adapter must use the landed buffer subsystem to
  open/activate existing files, honor its canonical identity/duplicate policy,
  retain dirty buffers and undo/session state, and report failure without losing
  the current document. A vanished discovered path must fail rather than follow
  startup `Controller.open_file`'s create-empty behavior. That subsystem must own
  highlighting/diagnostics and stale-document event isolation. Its result/focus
  and later open-at-location contracts remain dependencies, not guessed APIs.
- Added `file_picker/test/dune` and `file_picker/test/test_model.ml`: five headless
  tests cover raw/control/invalid-UTF-8 paths versus safe display, lexical rejection
  and nonexistent paths without IO, duplicate basenames and identity-based selection
  across reordered/incremental results, distinct discovery states/run identities,
  and a fake consumer receiving exactly one raw-path intent after host release,
  with no request on cancellation or empty selection.
- Checks used `opam exec --switch=5.2.0+ox --`: `dune runtest file_picker/test`,
  `dune build`, and `dune runtest file_picker/test palette/test screen/test source/test`
  pass. Full `dune runtest` fails only on snapshots in
  `ui/test/test_editor_view.ml`, matching the pre-existing default-visible-tile
  mismatch recorded in `FLOATING_TILES_PLAN.md`; no expectations were promoted.
  That baseline was not re-archived/rebuilt during this phase. An initial parallel
  build attempt hit Dune's concurrent-instance lock; the sequential retry passed.
  No live UI changes were made, so terminal smoke/human visual checks were not run.
- Dependency reinspection: `screen/floating.ml` and explicit floating layout
  resolution exist, but `screen/frame.ml` still uses tiled composition and
  `screen/ui_state.ml` still opens the palette in the bottom band and rejects zen.
  Floating compositor/palette migration remain pending, blocking phase 5 only.
  `app/controller.mli` still describes one document, offers startup `open_file`
  and current-document `jump`, and has no buffer open/activation API: phase 6
  remains blocked. No unrelated files were changed and no Git/GitHub mutations
  were performed.
- Next: implement phase 2 sequentially using this explicit request/snapshot and
  raw-path boundary. Establish root policy, bounded discovery/event delivery,
  cancellation/reaping, stale-run rejection, and producer invariants (root/run
  consistency, deterministic deduplication/order, resource limits). These are
  phase-2 work, not behaviors supplied by the phase-1 snapshot records. Phase 3
  must map matching positions into escaped display text; raw/display offsets can
  diverge. Phases 2–4 can proceed without floats or multiple buffers.

## Phase 2 — Project scope and asynchronous file discovery

**Possible without multiple buffers: YES.**
**Floating dependency: none.**

- Establish a project-root policy: proposed default is the nearest ancestor
  containing `.git` or `dune-project`, falling back to the starting document's
  directory. Recognize `.git` files as well as directories for worktrees.
- Keep the root explicit in the discovery request. Do not silently change the
  diagnostic root policy while sharing or extracting helper code.
- Start with `rg --files --null`, using an argument vector and explicit working
  directory, with no shell interpolation. Document ripgrep as a dependency and
  show actionable feedback when it is missing.
- Parse NUL-delimited paths, including spaces and newlines. Preserve original
  path bytes independently of safe rendered text.
- Respect ignore rules, include untracked files, and enforce the chosen hidden
  and metadata-directory policy. Do not follow directory symlinks by default.
- Deliver bounded batches asynchronously so discovery cannot monopolize input.
- Give each discovery run an identity. Ignore late batches after cancellation,
  reopening, or root changes; terminate/reap cancelled subprocesses.
- Represent loading, empty, partial-result, completed, and failed states distinctly.
- Keep candidate ordering deterministic and selection stable as batches arrive.

Tests should cover temporary directory trees, ignore behavior, unusual names,
empty projects, subprocess failure, cancellation, and stale delivery. Establish
an explicit result/memory limit or another bounded resource policy; disclose any
truncation in the UI rather than silently hiding files.

**Done when:** project file candidates can be obtained and refreshed without
blocking the editor or depending on tabs or floating rendering.

### Phase 2 implementation and handoff (2026-10-07)

- Added a separate Async library, `Ches_file_discovery`, under
  `file_picker/discovery/`: `dune`, `project_root.ml` / `.mli`, and
  `provider.ml` / `.mli`. The phase-1 `Ches_file_picker` library remains pure;
  its `dune` comment now points to the separate IO library. No diagnostic, screen,
  controller, or buffer implementation was changed.
- Root policy is the nearest ancestor with either `.git` (file or directory) or
  `dune-project`, starting at the document's directory and falling back to that
  directory. The starting directory is canonicalized when possible, otherwise
  made absolute lexically. `source/workspace_root.ml` and its marker-priority /
  diagnostic semantics are unchanged. The host must determine/retain a project
  scope and pass its explicit root; activating another same-project file must not
  implicitly rerun root policy. Roots are validated before replacing an active
  run, normalized for trailing slashes, and limited to 4 KiB.
- Provider launch uses `Async.Process.create`, an explicit working directory, and
  arguments `--no-config --files --null --glob !**/.git/** -- .` to `rg`; no shell
  is involved. Normal ignore rules apply, untracked files are included, hidden
  components and metadata are excluded, and directory symlinks are not followed.
  NUL-framed paths retain original bytes; only rg's leading `./` is stripped.
  Candidate lexical validation and escaped display remain the phase-1 boundary.
  Missing rg or bad working directories produce installation/PATH/access guidance;
  nonnormal exit, malformed framing and read failures produce Failed snapshots,
  retaining valid partial results. Exit codes 0 and 1 represent normal completion,
  including empty projects. Tool stderr is bounded and safely escaped.
- `Provider.create/start/request/cancel/finished/poll/snapshot` is the integration
  API. Call it on the Async scheduler and reuse one provider per host. Each start
  assigns a fresh identity and Loading snapshot. Worker batches use a pipe with
  zero size budget and write pushback (one queued batch); host polling consumes
  at most `max_batches` and rebuilds a sorted snapshot once per poll. Identity and
  root are checked on installation. Candidate maps deduplicate/order by exact raw
  relative path bytes. The pure model's identity-based result selection remains
  stable across these sorted incremental candidate sets; matching and model/tile
  integration are still later phases, not provider behavior.
- Cancellation immediately marks Cancelled, drops/closes the old delivery pipe,
  kills the child and closes streams. `finished run` acknowledges descriptor
  closure/reaping, not host consumption of the terminal status. Refreshes wait
  for preceding cleanup, even after explicit cancellation; at most one subprocess
  exists per provider. Cancellation while spawning and late/queued obsolete
  deliveries cannot alter a replacement run. Terminal status is separate from
  batch pushback so stalled host polling cannot prevent cleanup on timeout.
- Explicit defaults: 50,000 candidates; 4 KiB per emitted path; 8 MiB candidate
  string payload (root, joined absolute, relative, escaped display); 32 MiB scanned
  stdout; batches of 128; and 30 seconds wall time including backpressure.
  Count-bounded map/set/list overhead and transient record/batch buffers are
  additional to the string budget; consumers must not retain all old snapshots.
  Stderr drains concurrently in 4 KiB chunks retaining at most an 8 KiB prefix.
  Workers yield on bounded record groups even for duplicates/hidden paths, and
  on stderr chunks. Count/payload/path/output caps terminate and reap rg and set
  `Complete { truncated = true }`; timeout is Failed. Snapshots sort deterministically,
  but the capped subset follows traversal order, not a promised lexicographic
  prefix. `rg --sort` is deliberately avoided to avoid unbounded subprocess
  file-list storage. The future phase-4 UI **must display truncation and errors**;
  there is no UI in this phase and no silent live truncation behavior.
- Added `file_picker/discovery/README.md` with dependency, scope, lifecycle,
  ignore/symlink policy, resource bounds, and future-host obligations. Added
  `file_picker/discovery/test/dune`, `test_discovery.ml`, and
  `test/fake_rg/dune` / `fake_rg.ml`. Ten headless Async tests exercise temporary
  trees, nearest mixed markers/worktree files, canonical/fallback roots, real rg
  ignores/untracked/hidden/symlink behavior, odd raw filenames, NUL records across
  reader buffers, empty projects, batch backpressure, deduplication/order/stable
  model selection, failed spawn/bad root/tool exit/malformed output, safe bounded
  stderr, every truncation limit, request validation, cancellation and reaping,
  stale root/run deliveries, refresh during spawning, and timeout without polling.
  The fake executable is an actual directly spawned child (no shell wrappers);
  reaping assertions specifically require ECHILD for its recorded PID. Fixture
  cleanup only removes test-created trees and does not follow directory symlinks.
- Checks used `opam exec --switch=5.2.0+ox --`: focused `dune runtest file_picker`,
  broader `dune runtest file_picker palette/test screen/test source/test`, and
  `dune build` pass. Full `dune runtest` still fails only on
  `ui/test/test_editor_view.ml`'s already-recorded default-visible-tile snapshots;
  no expectations were promoted and that baseline was not re-archived. No live
  UI changed, so terminal smoke and human visual review were not run. These are
  safety/correctness checks, not performance measurements or responsiveness claims.
- Dependencies remain unchanged: phases 3–4 can proceed headlessly without floats
  or buffers. `app/controller.mli` still owns one document, has startup open semantics,
  and lacks open/activate-existing-buffer support; phase 6 is blocked. Shared
  floating compositor/palette migration are still phase-5 dependencies and were
  not implemented here. Next agent should implement **phase 3 only**, reuse the
  pure candidate display/raw boundary, map matching offsets into escaped display,
  test loose file matching independently of command matching, and record query
  scale measurements. Do not treat `finished` as a discovery snapshot notification
  or route picker batches through diagnostic events. UI polling, model discovery
  installation, root retention across actual buffer activation, and visible
  truncation belong to subsequent integration phases. No Git/GitHub mutations or
  publication/attribution occurred; phase-1 and unrelated work were preserved.

## Phase 3 — File-oriented fuzzy matching

**Possible without multiple buffers: YES.**
**Floating dependency: none.**

Reuse `Ches_palette.Fuzzy` with basename and project-relative path fields, giving
the basename greater weight. Preserve byte-offset match positions and map any
basename-field highlights into the displayed relative path.

The existing matcher rejects matches below a quality threshold. Make matching
policy configurable so file search can accept loose subsequences without
changing command-palette behavior. This is subsequence matching, not spelling
correction; full fzf compatibility is not assumed.

Build representative acceptance examples: directory plus basename tokens,
initials, scattered path abbreviations, duplicate basenames, punctuation,
non-ASCII paths, empty queries, and no matches. Obtain real user query examples
before considering ranking settled.

Measure discovery-independent query latency on realistic and large path sets.
The current engine prepares candidates and sorts all matches on every query.
Cache prepared candidates or add bounded top-result ranking if measurements
justify it. Merely rendering fewer rows does not reduce matching work. If ranking
is asynchronous, reject stale query results as well as stale discovery batches.

**Done when:** file matching has useful tested ranking, reliable highlighting,
and recorded scale measurements without regressions in command matching.

### Phase 3 implementation and handoff (2026-10-07)

- Changed `palette/fuzzy.ml` / `.mli`: explicit `Policy.Command` (the existing
  50-percent quality threshold, still the default) and opt-in
  `Loose_subsequence` (accept all ordered subsequences, including negative scores).
  Both preserve ASCII folding, Unicode equality, weights, alignment scoring,
  stable ties, whitespace token semantics, and byte-offset positions. Added an
  immutable `Prepared.create` / `rank_prepared` API for reusable field decoding.
  Existing `rank` prepares one candidate at a time and does not prepare fields on
  blank queries, retaining the command caller's previous lifecycle. No command
  catalog, palette interaction, or command policy call site changed.
- Added `file_picker/search.ml` / `.mli`: pure synchronous `Search.prepare` and
  `Search.rank`, using raw basename (150 percent) and relative path (100 percent)
  fields. Every token independently chooses its best field. Basename offsets are
  shifted into the raw relative path, token/field highlights are merged, then
  mapped to escaped display UTF-8 byte starts. Empty queries and equal scores
  preserve input order: pass the provider's deterministic sorted collection.
  `file_picker/dune` now depends on `ches_palette` as well as Core; it remains
  pure and independent of Async, screen, controllers, floats, and buffers.
- Changed `file_picker/model.ml` / `.mli`: `Candidate.display_positions` shares
  the existing escape encoder rather than duplicating its sanitization policy.
  Normal paths use the direct byte-offset fast path; escaped paths map scalar
  starts and highlight entire hex escapes/doubled backslashes. Valid non-ASCII
  text highlights only code-point starts, never continuation bytes. Raw candidate
  paths and open intents are unchanged. Escaped spelling is display-only: typing
  `xFF` is not an alias for a malformed raw byte. ASCII whitespace remains query
  token separation, not a literal whitespace-filename search syntax.
- Changed `palette/test/test_fuzzy.ml`; added
  `palette/test/test_fuzzy_policy.ml` and `file_picker/test/test_search.ml`; updated
  `file_picker/test/dune`. Six new headless tests cover opt-in negative-score
  subsequences/default command filtering, prepared/uncached equality, exhaustive
  independent subsequence checks (1,953 combinations), basename preference,
  contiguous/initial/camel ranking, directory-plus-basename tokens, duplicate
  basename stable ties, scattered path abbreviations, punctuation, Unicode,
  empty/no-match/typo queries, merged/shifted highlights, invalid bytes, controls,
  doubled backslashes, multi-byte escaped scalars, and raw acceptance-path safety.
  Existing command ranking and palette/screen tests pass unchanged. These are
  representative engineered examples, **not owner-supplied query validation**.
- Added `file_picker/bench/dune`, `query_latency.ml`, and `README.md` with the
  reproducible probe, method, dataset identity, results, tradeoffs, and caveats.
  Discovery-independent monotonic samples (10 per query/mode after warmup) cover
  this repository's 258 paths and synthetic 1k/10k/50k source trees. Cached matching
  includes final highlight mapping; uncached excludes that conversion. Final
  50k medians: empty 2.120 ms, `m` 34.987 ms, `model` 24.855 ms, `src mod`
  25.527 ms, `sfp` 15.058 ms, no-match 9.616 ms. Corresponding nonempty uncached
  medians are 106.488 / 94.474 / 101.769 / 88.014 / 81.293 ms. Real-project
  nonempty cached medians range from 0.019 to 0.086 ms. These are local headless
  observations, not input-to-screen latency, p99 estimates, or a responsiveness
  guarantee; no target budget has been agreed.
- Measurements justify decoded-field caching and an O(path length) feasibility
  prefilter in the shared matcher that skips DP allocation for impossible fields.
  Cached 50k `model` improves from 63.042 to 24.855 ms and no-match from 63.535 to
  9.616 ms; allocation drops from 265.0 to 66.0 MB/query and 293.0 to 4.8 MB/query.
  Broad `m` still allocates 110.8 MB/query and did not improve with the prefilter.
  Prepared 50k storage adds about 78.05 MiB and takes 153.501 ms to build, outside
  the provider's candidate-string budget. Host integration must release old
  snapshots and avoid blindly preparing on every delivered batch. Incremental
  reuse, bounded top-result ranking, async scheduling, and long-query/4 KiB-path
  stress work are not implemented or claimed necessary/sufficient here. All
  results are still scored/sorted; rendering fewer rows is not an optimization.
- Checks using `opam exec --switch=5.2.0+ox --`: focused and broader
  `dune runtest file_picker palette/test screen/test source/test` pass, and
  `dune build` passes. Full `dune runtest` still fails only on the recorded
  `ui/test/test_editor_view.ml` default-visible-tile snapshots; no expectations
  were promoted or baseline re-archived. An initial edit-tool UTF-8 roundtrip
  altered two pre-existing malformed-byte expectations in the command test;
  their exact original bytes were restored and the unchanged tests then passed.
  No live UI was added, so terminal smoke/human visual checks were not run.
- Phase 3's independent deliverable is implemented; ranking remains provisional
  until actual owner queries are obtained. Next is **phase 4 only**: integrate
  query/model/tile behavior headlessly, show loading/partial/errors/truncation,
  preserve selection, and use a fake acceptance consumer. Query preparation and
  synchronous filtering need an intentional batching/scheduling policy informed
  by these measurements, not a claim that 50k-path keystrokes are already cheap.
  Discovery run/root freshness is still the host's job; if ranking later becomes
  asynchronous, also reject stale query results. Phases 5 and 6 still depend on
  shared floating composition and the actual multi-buffer open/activate API;
  neither was implemented here. Existing phase-1/2 and unrelated work were
  preserved. No mutative Git operations, GitHub changes, publication, or AI
  attribution were performed.

## Phase 4 — Shared picker interaction and file tile

**Possible without multiple buffers: YES.**
**Floating dependency: none for headless model/rendering; live overlay is phase 5.**

Extract only the reusable parts of the command palette: query editing and
sanitization, stable selection, scrolling, query cursor, and matched-text rendering.
Keep command catalogs/dispatch and file discovery/open intents separate. Avoid a
large provider framework or view-registry rewrite.

Add a file-picker tile adapter that renders discovery status, query, relative
paths, selection, counts, and errors. Selection should survive incremental result
updates when its candidate remains present. Define an intentional fallback when
it disappears. Enter with no selection must do nothing.

The tile emits an acceptance intent to an injected or fake consumer for tests.
It must not expose a live file-opening keybinding backed by a no-op implementation.

**Done when:** file-picker input and rendering work headlessly, cancellation emits
no open request, acceptance emits exactly one request, and command-palette
behavior remains verified.

### Phase 4 implementation and handoff (2026-10-07)

- Added `palette/query.ml` / `.mli` and `palette/selection.ml` / `.mli`; changed
  `palette/palette.ml` to reuse single-line sanitization, UTF-8 backspace, word
  deletion and identity-preserving selection with the original first-result
  fallback. Added `screen/picker_text.ml` / `.mli`; changed
  `screen/palette_tile.ml` to reuse query-tail clipping/cursor and byte-position
  matched-text rendering. Existing command-specific catalogs, acceptance and
  keybindings remain unchanged. Scrolling reuses `Ches_tile.Navigation.Selection`,
  not a new provider framework or registry.
- Changed `file_picker/model.ml` / `.mli`: shared selection fallback, a metadata-only
  `with_discovery` installer (caller validates freshness), and `Candidate.display_text`
  exposing the existing encoder for safe root/error metadata including NUL. Raw
  candidate paths and open intents remain distinct from escaped display strings.
- Added `file_picker/interaction.ml` / `.mli`: single-owner mutable headless session,
  palette-style query events, run/root rejection, incremental snapshot installation,
  coalesced queries/jobs, prepared-field caching by raw absolute path, clamped
  navigation, stable selection and explicit bounded work turns. Neither input nor
  rendering prepares/ranks the whole dataset. Work processes at most its positive
  candidate/output-record budget (suggested 128); per-candidate matching and ordered
  score/input-index map inserts preserve phase-3 full ranking/ties. Superseded jobs
  cannot publish. Status-only snapshots sharing the candidate list avoid reranking;
  cache entries from abandoned jobs are reused and obsolete entries are dropped on
  publication. Provider owns same-run ordering, valid/deduplicated candidates and
  resource bounds; refresh/reopen requires a new session/run.
- Pending work keeps old results visible with a filtering label but disables
  navigation/acceptance until atomic publication. Enter is not queued. Selection
  survives if its identity remains; disappearance selects first or none. Acceptance
  marks closed/drops work/cache/candidates/results, invokes the host-supplied release
  callback, then delivers exactly one typed raw-path intent to an injected consumer.
  Repeated/reentrant acceptance and cancellation are inert. Empty/pending selection
  leaves the session open without effects. Release must cancel provider discovery
  and release input/paste capture before consumption; exceptions are not retried.
- Added `screen/file_picker_tile.ml` / `.mli`; changed `screen/dune` and
  `screen/test/dune` dependencies. Adapter presents escaped root in title, query,
  loading/partial/completed/failed/cancelled status, explicit truncation, relative
  paths/matched styles, selection, counts and distinct empty/no-match messages.
  Status/error is also in footer; narrow allocations clip but never overrun.
  Query + status + result requires **three content rows** in phase 5, unlike the
  command palette's two-row minimum. Shared shell/host/floating systems were not
  implemented or modified. No live file-opening keybinding or no-op opener exists.
- Added `file_picker/test/test_interaction.ml` (four tests) and
  `screen/test/test_file_picker_tile.ml` (three tests). Assertions cover bounded
  preparation/cumulative decode counts, reuse across batches/queries, coalesced and
  partially emitted obsolete jobs, stable/fallback selection and movement clamps,
  stale root/run/closed installation, exact equality to `Search.rank`, Unicode and
  sanitized paste/editing, raw-path once-only/reentrant fake acceptance after release,
  pending/empty Enter and cancellation, every discovery status/errors/NUL/truncation,
  root/path display, matched spans, viewport scrolling, query cursor and bounded
  rendering at negative/zero/tiny sizes. Existing palette regressions pass unchanged.
- Added `file_picker/README.md` with future-host obligations and explicit scheduling,
  selection and memory policies. Added `file_picker/bench/interaction_latency.ml`,
  changed `file_picker/bench/dune` and `bench/README.md` with a reproducible cache/work
  probe on the phase-3 synthetic fixtures. Single headless observations at 50k:
  initial preparation/publication 234.507 ms total, longest 128-record turn 3.951 ms;
  cached `m` / `model` / `src mod` / no-match totals 74.196 / 69.399 / 72.085 /
  52.218 ms, longest turns 0.741 / 1.654 / 0.624 / 0.599 ms. Decode count remains
  50k across all queries; retained post-initial state adds about 82.44 MiB, beyond
  candidate strings/provider state (phase-3 preparation alone was about 78.05 MiB).
  Chunking adds CPU overhead versus whole-list queries; it is not a speedup.
  Broad queries need 782 turns, so phase 5 must yield/schedule work between redraws,
  not restrict it to one work turn per frame or drain it inside a key callback.
  These are one-run measurements, not p99, peak RSS or input-to-screen guarantees.
- Bounded record counts are not hard time bounds: final explicit publication does
  O(results) reversal/selection validation; navigation, fitting and counts scan
  lists. Long queries/4 KiB paths, GC tails, in-flight map/result memory, actual
  Async wakeup/yield strategy and terminal responsiveness remain unmeasured.
  No target responsiveness budget or owner ranking examples have been supplied.
- Checks with `opam exec --switch=5.2.0+ox --`: `dune build`, focused/broader
  `dune runtest file_picker palette/test screen/test source/test`, and a final forced
  rerun of those suites pass. The interaction latency executable passes its decode
  reuse assertions. Full `dune runtest` fails only on the already-recorded
  `ui/test/test_editor_view.ml` default-visible-tile snapshots; none promoted and
  no baseline re-archive was done. `git diff --check` passes (read-only). Initial
  build/test compilation errors during development were corrected before the final
  passing checks. No live UI changed; terminal smoke/human visual checks not run.
- Dependency reinspection: `screen/floating.ml` geometry and explicit
  `Ui_state.view_layout ~floating` availability exist. `screen/frame.ml` still renders
  tiled panes without floating overlay composition; `Ui_state.open_palette` still
  allocates the bottom band and rejects zen. **Phase 5 remains blocked on shared
  floating compositor and palette migration**; do not implement a parallel float.
  `app/controller.mli` still owns one document and startup `open_file` can create
  empty files; there is no buffer open/activation API. Phase 6 remains blocked on
  that actual API. Phase 4's independent headless deliverable is complete, not a
  live usable file opener. Phases 1–3 and unrelated working-tree work were preserved;
  no mutative Git operations, GitHub changes/publication or attribution occurred.

## Phase 5 — Floating host integration

**Possible without multiple buffers: YES, using a test acceptance consumer.**
**Floating dependency: shared compositor and palette migration must be available.**

Connect the file tile to shared floating placement, shell, focus, input routing,
paste handling, and cursor ownership. Reuse the established one-transient-float
policy, including minimum-size and resize behavior. Opening the picker must not
reallocate the underlying workspace.

Verify open/type/select/cancel, no-match Enter, zen mode, small terminals, resize,
focus restoration, and interrupted paste. Assert that closing a picker cannot
leak late pasted text or discovery events into the document or a new picker.

Keep acceptance routed to a test consumer until phase 6 is available. This phase
can validate the entire floating interaction but is not a user-ready file opener.

**Done when:** the floating file picker is fully exercised through the host with
an isolated acceptance boundary and unchanged underlying document state.

## Phase 6 — Connect tabs/buffers and ship `Space f f`

**Possible without multiple buffers: NO — blocked on that feature's opening API.**
**Floating dependency: phase 5.**

Inspect the landed tabs/buffers API and adapt the phase-1 acceptance contract to
it. Leave branch reconciliation to the human under the Git constraints above.

- Wire Normal-mode `Space f f` and a discoverable command-palette entry.
- Close/release picker input capture and dispatch the open intent exactly once.
- Activate already-open files according to the buffer system's identity policy.
- Preserve unsaved buffers; do not add save-before-switch behavior.
- Surface unreadable, removed, or unsupported files without losing the current
  document. Define focus restoration on failure.
- Ensure an enumerated file that disappears is not silently treated as a request
  to create a new empty document.
- Confirm the buffer subsystem correctly updates highlights and diagnostics and
  rejects stale events from previously active documents.
- Verify project-root behavior when activating files from different projects.

**Done when:** a user can find and open files, revisit an existing dirty buffer,
cancel safely, and recover from failed opens in the real editor.

## Phase 7 — Fuzzy lines in the current document

**Possible without multiple buffers: YES.**
**Floating dependency: phase 5's reusable UI; phases 1, 3, and 4 supply foundations.**

This can proceed independently of phase 6. Search lines from the current
**in-memory document**, including unsaved edits, rather than rereading the file.
Display line numbers and matched text. Accepting jumps within that document,
using `Controller.jump` or the equivalent current API.

Capture document identity and revision when opening. Define how edits or document
changes invalidate/refresh results so acceptance never jumps using stale line
coordinates. Convert matcher byte offsets to the navigation API's coordinate
convention rather than treating bytes as display columns.

Choose a non-conflicting binding before shipping. Verify unsaved text, duplicate
lines, Unicode coordinates, cancellation, and large-document responsiveness.

**Done when:** fuzzy current-document line search works without filesystem
traversal or cross-buffer opening.

### Phase 7 implementation and handoff (2026-10-07) — PARTIAL

- Added `line_picker/dune`, `lines.ml` / `.mli`, `README.md`: a separate headless
  current-document snapshot/provider and session, with no IO/traversal. Reads
  `Controller.editor` / `Editor.text`, including unsaved contents. Reuses shared
  fuzzy prepared fields/loose policy, query sanitization/editing, and stable
  selection foundations. Line numbers (one-based) distinguish duplicate text;
  blank and final trailing-LF lines remain candidates. Work is explicitly bounded
  by line/output records; input and rendering do not drain ranking. Prepared
  lines are cached across queries; superseded jobs cannot publish. Pending Enter
  is inert; selection persists or falls back to first/none.
- Changed `app/controller.ml` / `.mli`: opaque runtime `Document_id`, fresh on
  creation/successful reload and preserved through ordinary record transitions.
  Session freshness checks identity + revision + immutable text identity, including
  same-revision divergent immutable controller branches. A mismatch permanently
  drops snapshot/cache/work/results; reopen to refresh. Hosts must validate on
  controller changes and before rendering; acceptance always checks itself.
- Changed `core/editor.ml` / `.mli`: byte-boundary-to-one-based-display-coordinate
  conversion using the editor's own width function. Acceptance targets the earliest
  raw match byte (line start for blank query), not line-number/display text offsets.
  TABs, wide glyphs, controls and multi-byte scalars are handled by Cell_layout.
  Zero-width/combining characters map to the preceding visible glyph/first cell;
  existing display-cell navigation cannot select them independently.
- Added `screen/line_picker_tile.ml` / `.mli`; changed `screen/dune` and
  `screen/test/dune`: line-number/text/match rendering, whole-line TAB layout,
  query cursor, scroll selection, in-memory label, filtering, invalidation and
  visible truncation. Headless acceptance returns a real `Controller.jump` result:
  close exactly once, release capture, reread current controller, revalidate,
  convert coordinates, jump. Host installs returned controller synchronously.
  Stale/mode errors perform no jump; cancellation is once-only. No live registry,
  binding, compositor, or buffer-system change was made.
- Limits: first 50k lines, 8 MiB raw line payload, 4 KiB per line; stop at the first
  exceeded cap rather than silently skip lines. Length is checked before copying
  a long line. Snapshot references current immutable text; decoded arrays/maps and
  in-flight results add overhead beyond payload budget. Closing/invalidation drops
  retained document/cache/results. Record budgets do not bound DP/GC time; final
  publication/list navigation/fitting have O(results) operations.
- Added `line_picker/test/dune`, `test_lines.ml` (six tests), and
  `screen/test/test_line_picker_tile.ml` (two tests): dirty text without disk reads,
  duplicates, trailing/empty lines, shared matching equivalence, Unicode editing,
  raw byte versus display-cell coordinates, TAB/wide/control/combining policy,
  identity/revision/undo/same-revision-branch invalidation, changes during release,
  once-only acceptance/cancel, pending/no-match Enter, mode errors, bounded work,
  coalescing/cache/selection, all resource caps, scrolling and tiny allocations.
- Added `line_picker/bench/dune`, `latency.ml`: reproducible monotonic 1k/10k/50k
  synthetic in-memory source-line probe, 128-record turns. At 50k, initial blank
  preparation 174.238 ms total / 2.518 ms longest turn; cached `m` 46.586 / 2.019,
  `model` 97.848 / 1.354, `let value` 139.959 / 1.415, no-match 23.080 / 1.108 ms.
  Decodes remain at 50k; broad queries use 782 turns. Single headless observations,
  not p99/input-to-screen/RSS guarantees; no responsiveness budget agreed.
- Checks with `opam exec --switch=5.2.0+ox --`: `dune build`, focused/broader
  `dune runtest line_picker/test file_picker palette/test screen/test source/test`
  pass; scale probe passes reuse assertions. Full `dune runtest` fails only on
  the previously recorded `ui/test/test_editor_view.ml` default-visible-tile
  snapshots; none promoted, baseline not re-archived. Initial compile/test errors
  were corrected. Final forced rerun of the focused/broader suites and read-only
  `git diff --check` pass. No live integration changed, so no terminal/human visual review.
- **Remaining phase 7:** phase-5 shared floating compositor/palette migration is
  still unavailable (`Frame` tiled composition; palette bottom-band/zen restriction).
  Wire this adapter to the landed transient float host, yielded work scheduling,
  controller-change invalidation, focus/paste/cursor ownership, resize/min-size
  behavior and viewport reveal. Choose/check a non-conflicting Normal binding and
  discoverable command entry then; verify live unsaved/Unicode jump/cancel and late
  paste isolation in zen/small/resized terminals. Do not ship a no-op binding or
  parallel compositor. Phase 6 remains blocked on buffers but is not needed for
  current-document jumping. **Phase 7 is PARTIAL, not live usable or complete.**
- Next: retain this independent implementation while the human lands prerequisites;
  do not implement phase 8 yet. Existing phases 1–4/unrelated work preserved;
  no mutative Git operations, GitHub mutation/publication or attribution performed.

## Phase 8 — Project-wide content search

**Possible without multiple buffers: PARTIAL.**
**Independent portion:** provider, results model, UI, and fake-consumer tests.
**Blocked portion:** real cross-file acceptance requires phase 6 and open-at-location.

Start with ripgrep-backed live literal search, with regex behavior explicitly
selected if offered. Do not label it arbitrary fuzzy matching across all project
contents. A later mode may fuzzy-filter a bounded set of returned matches.

- Use structured results, such as `rg --json`, retaining path, line, match offsets,
  and text separately; do not parse colon-delimited display rows.
- Debounce requests where useful, cancel obsolete searches, reject stale results,
  and bound result count and memory. Display truncation and errors explicitly.
- Share root/ignore policy with file discovery. Define empty-query behavior so it
  does not inadvertently stream the entire repository.
- Initially search on-disk contents and label that behavior; incorporating dirty
  buffers is a separate policy requiring cooperation from the buffer subsystem.
- Accept via open-at-location, validating location coordinates against the opened
  document because files may change between search and acceptance.

**Done when:** independent provider/UI checks pass, and, once the dependency lands,
selecting a match opens or activates the correct file and navigates correctly.

### Phase 8 implementation and handoff (2026-10-07) — PARTIAL

- **Done (independent portion):** added pure `content_picker/model.ml` / `.mli`
  and `dune`, plus Async `content_picker/provider/provider.ml` / `.mli` and
  `dune`. Structured `rg --json --fixed-strings --case-sensitive --line-number
  --color never -- QUERY .` uses an argument vector and explicit root, never a
  shell. Added `file_picker/scope.ml` / `.mli`; file discovery now shares its
  no-config/ignore/hidden/metadata/no-follow policy with content search without
  changing diagnostic root discovery. Hosts reuse phase-2 `Project_root.find`
  and retain scope explicitly; no root re-selection is hidden in query refreshes.
  `dune-project` declares direct Yojson/Base64 dependencies (generated `ches.opam`).
- JSON `text` and base64 `bytes` fields preserve raw paths and lines (including
  invalid UTF-8/controls/line endings). Only leading `./` is stripped. Each
  submatch is one hit, separately retaining path, positive one-based line,
  zero-based raw byte start/end (exclusive) and raw text. Parser validates literal
  agreement and offset bounds; malformed JSON/paths/offsets fail with valid partial
  hits retained. This is case-sensitive literal substring search, not fuzzy or
  regex. **Empty query never launches rg or enumerates contents**; whitespace is
  literal. Initially **ON DISK**, explicitly excluding unsaved edits. Ripgrep's
  normal binary detection applies; no binary override or multiline queries.
- Provider API is `create/start/request/cancel/finished/poll/snapshot`. Fresh
  run/root/query identities, 150ms debounce, private per-run pipes, immediate
  cancellation, closure and child reaping precede replacement launch. At most one
  subprocess/queued batch per provider; cancelled debounced runs never launch.
  Worker deliveries cannot write editor state or replacement snapshots. Host polls
  bounded batches; `finished` means reaped/closed, not consumed terminal status.
  Terminal state is separate from batch pushback so timeout reaps without polling.
- Defaults: 10k occurrences, 4KiB raw path/line, 64KiB JSON record, 8MiB retained
  string payload, 32MiB stdout, batches of 128, 10s launched-run timeout including
  backpressure. Stderr drains concurrently in 4KiB chunks retaining an 8KiB prefix.
  Count/path/line/payload/record/output caps kill/reap and publish **TRUNCATED**, not
  silent omission; timeout/read/process/parse failures are visible Failed states.
  Exit 1 is normal no-match. Traversal order/capped subset is not a sorted prefix.
  Decoded JSON/base64, queued batches/list overhead and rendered escapes are extra
  memory; snapshot reversal/selection/navigation/fitting are O(hits), not hard
  time bounds. No live latency/p99/RSS/responsiveness claim or benchmark target.
- Added `screen/content_picker_tile.ml` / `.mli`; extended existing screen/test
  dependencies only. Headless tile reuses palette editing/sanitization/key
  interpretation, Picker_text query/cursor, navigation selection, Span/shell.
  It shows root, on-disk semantics, byte-column convention, query, safe paths/text,
  highlighted literal occurrence, loading/partial/no-match/errors/truncation in
  status/footer, scroll selection and bounded small-size rendering. Query editing
  immediately disables stale acceptance; exact run/root/query snapshot checks,
  identity selection retention and first/none fallback apply. Query shortening at
  a complete UTF-8 boundary within 4KiB is visibly labelled QUERY TRUNCATED.
- Once-only acceptance closes/drops hits, invokes injected release, then delivers
  a typed raw-path intent to a **fake consumer only**. Intent retains one-based
  line, zero-based byte column/end, expected raw line and literal. UI prints
  one-based **BYTES, not cells**. No byte offset is sent to Controller.jump.
  Future consumer must open/activate an existing file via actual buffer API,
  validate current contents/dirty-buffer policy against the searched line/literal,
  then convert with the opened document's coordinate API. Changes/disappearance
  must fail visibly or refresh, never create an empty file or blindly jump.
- Added `content_picker/provider/test/dune`, `test_search.ml` (nine headless Async
  tests), directly spawned `test/fake_rg/dune` / `fake_rg.ml`, and
  `screen/test/test_content_picker_tile.ml` (two tests). Cover real rg ignore,
  hidden/metadata/symlink/untracked policy; punctuation/case/whitespace literals;
  base64 and UTF-8 fields, unusual raw paths/lines, multiple occurrences, Unicode
  byte positions; empty/no-match/validation/spawn/access/tool/JSON errors; all caps;
  safe bounded stderr and partial retention; debounce, cancellation/backpressure,
  timeout without polling, refresh while spawning, root/query stale isolation;
  ECHILD reaping assertions; stable/fallback selection, edited/empty/closed Enter,
  once-only/reentrant fake consumption after release, display highlights/status,
  scroll/cursor/tiny allocations and visible query truncation.
- Checks use `opam exec --switch=5.2.0+ox --`: `dune build` and focused/broader
  `dune runtest content_picker file_picker line_picker/test palette/test screen/test
  source/test --force` pass. Full `dune runtest` still fails only on the recorded
  `ui/test/test_editor_view.ml` default-visible-tile snapshots; no expectations
  promoted or baseline re-archive performed. Initial new compile/assertion issues
  were fixed before passing checks. Read-only `git diff --check` passes. Detailed
  files/checks/host obligations are in `content_picker/README.md`, `RESULTS.md` and
  `HANDOFF.md`. No live UI changes: terminal smoke/human visual review not run.
- **Pending/blocked:** shared floating compositor/palette migration (Frame still
  tiled; palette bottom-band/zen restriction) for real capture/focus/cursor/paste,
  min-size/resize and yielded polling/redraw; actual phase-6 multi-buffer
  open/activate-existing and open-at-location API, opened-content validation,
  byte-to-navigation conversion, dirty-buffer/failure/focus policy and end-to-end
  verification. A live binding/discoverable command must wait for these dependencies.
  No parallel compositor, guessed buffer API, live no-op binding or real opening
  adapter was added. **Phase 8 is PARTIAL, not shipped/complete.** Existing phases
  1–4/7 and unrelated changes preserved; no mutative Git operations or GitHub
  mutation/publication/attribution occurred. Phase-7's historical “do not implement
  phase 8 yet” next-step note was superseded by the explicit phase-8 user request.

## Phase 9 — Release verification and documentation

**Possible without multiple buffers: PARTIAL.**
Independent phases can be checked and documented immediately. End-to-end file
opening and project-search acceptance require the multi-buffer integration.

- Run focused tests for the changed components, then the appropriate build and
  broader checks using the repository's documented OxCaml toolchain.
- Record pre-existing failures separately; do not promote unrelated snapshots.
- Extend terminal smoke coverage for file-picker interaction and real acceptance
  once phase 6 is available.
- Record human terminal review separately from automated verification.
- Document bindings, search root, ignored/hidden files, ripgrep requirements,
  matching semantics, limits, and on-disk versus in-memory content search.
- Record representative discovery and query latency measurements. Agree on a
  target dataset and responsiveness budget before claiming performance is done.

### Phase 9 implementation and handoff (2026-10-07) — PARTIAL

**Achievable independent portion completed. Not a release/terminal acceptance.**
Phases 1–4 remain implemented, phase-3 ranking provisional, phases 7–8 PARTIAL,
phase 5 blocked by floating composition/migration, and phase 6 blocked by buffers.

#### Review and fix

- Reviewed phase-1–4 implementation and phase-7/8 independent integration against
  their handoffs, floating plan and current code. Checked raw/display path separation,
  shared query/selection/matcher extraction, byte-offset highlights, document identity
  and revision freshness, display-cell conversion, and typed acceptance boundaries.
  File/content acceptance still uses injected consumers; line acceptance produces an
  actual current-document jump only after release and revalidation. Closing first
  makes repeated/reentrant acceptance/cancel inert; empty/pending Enter is not queued.
- Reviewed provider run/root/query isolation, private delivery pipes, debounce,
  cancellation while spawning, replacement cleanup, concurrent bounded stderr
  draining, backpressure, cap/timeout termination and descriptor closure/reaping.
  Existing fake-child tests assert ECHILD, not just signal delivery. Providers retain
  their bounded last snapshot on cancel until refresh/disposal; hosts separately
  close sessions and drop historical snapshots. Documented this ownership explicitly.
- **Fixed a material provider/interaction scheduling mismatch:** discovery `poll`
  rebuilt `Map.data` on terminal-only status changes, breaking the physical-list
  identity contract used by `Interaction.install`. Completion/failure unnecessarily
  restarted full filtering and disabled acceptance even if candidates were unchanged.
  `poll` now reuses the previous candidate list when no candidate delivery occurred.
  Added a directly spawned fake-rg regression crossing real provider polling into
  `Interaction`: terminal-only completion preserves candidate identity and leaves
  already-published filtering idle. This test failed at the identity assertion before
  the fix and passes afterwards; no failing expectation was promoted.
- No additional material correctness defect found in the reviewed boundaries.
  This does not prove live focus/paste/cursor ownership: those adapters are absent.
  Reinspected `Frame`/`Ui_state`: tiled composition and bottom-band/zen palette
  restrictions remain. `Controller` is still single-document with create-empty
  startup semantics, not an existing-buffer/open-at-location consumer. No picker
  binding/catalog entry or live UI registry integration was found or added.
- Confirmed record/payload caps are not hard per-turn time/RSS bounds: per-candidate
  DP/GC, publication, selection, navigation, fitting/counting and provider snapshot
  materialization still have significant work. Cache is additional to provider
  strings. Yielded live work/poll/redraw scheduling remains phase-5 work; no attempt
  to hide it behind a no-op binding or parallel float/buffer implementation.

#### Changed files in this phase

- `file_picker/discovery/provider.ml` / `.mli`: metadata-only candidate-list reuse
  and explicit integration contract.
- `file_picker/discovery/test/test_discovery.ml`: provider-to-session regression.
- `file_picker/bench/dune`, `discovery_latency.ml`, `README.md`: reproducible bounded
  headless discovery probe, raw samples/dataset identities and caveats; preserved
  existing query/interaction probes and historical results.
- `README.md`, `docs/editor_reference.md`, new `docs/pickers.md`: unmistakable
  implemented-foundations versus unavailable-live-feature status, planned/unbound
  bindings, setup/dependencies, root/ignore policies, matching modes, bounds,
  on-disk versus in-memory search, coordinates and exact release blockers.
- `file_picker/discovery/README.md`, `content_picker/README.md`: corrected current
  headless-tile status and cancellation snapshot ownership. `content_picker/HANDOFF.md`
  links this final independent review while retaining its blocked live obligations.
- This plan: updated overall status and final independent verification/handoff.
  All pre-existing phase/unrelated working-tree changes preserved; no mutative Git
  operations, GitHub mutation/publication or attribution. One sequential agent;
  no delegated/subagent work.

#### Final check record

All Dune commands use `opam exec --switch=5.2.0+ox --` and ran sequentially.

| Check | Actual outcome |
| --- | --- |
| `dune build` (initial and final) | PASS |
| New discovery regression before fix: `dune runtest file_picker/discovery/test` | Expected reproduction FAIL at candidate-list identity assertion; not promoted |
| `dune runtest content_picker file_picker line_picker/test palette/test screen/test --force` after fix | PASS, including the new provider/session regression and existing cancellation/reaping, stale delivery, coordinates, bounds and acceptance tests |
| `dune runtest --force` (one final broad run) | FAIL only on the known `ui/test/test_editor_view.ml` snapshot mismatch; all other suites, including core/app/source/LSP, pass |
| Discovery probe, repository + synthetic 10k tree | PASS; stable counts, untruncated completion/cleanup |
| `git diff --check` (read-only) | PASS |
| Picker terminal smoke / human terminal review | NOT RUN / unavailable: no live host or real opening adapter |

Full-suite log: `/tmp/opencode/file-picker-phase9-runtest.log` (temporary local log).
Actually observed **seven mismatched expectation blocks across four UI tests**:
“the app renders, edits, and follows resizes” (two blocks), “events in one frame
all apply, in order” (one), “Space q exits once; later input is ignored” (one), and
“Space v layout commands move the tile, and resizes keep the request” (three).
Actual frames show default-visible Status/Problems/History and changed cursor
geometry instead of the old framed-document/bottom-status expectations. The
12×3 compact snapshot agrees. No source/LSP failure occurred in this final run.
No UI expectations promoted or edited; prior baseline evidence remains the floating
plan's historical isolated-baseline reproduction, not a fresh baseline comparison.
The broad suite was not repeated without reason. Existing terminal smoke coverage
was not extended or represented as picker acceptance.

#### Measurements and exact remaining blockers

- Added ten-sample discovery measurements (after one warmup), monotonic provider
  start to installed terminal snapshot plus reaping/closure. rg 14.1.0; default
  limits; one batch polled per turn, 1 ms waits while loading; warm filesystem,
  natural GC/uncontrolled load; no ranking/terminal rendering. Repository 325 paths:
  median/max **6.294/6.551 ms**; deterministic generated 10k tree:
  **103.017/105.777 ms**. Probe source, raw samples, path manifest hashes and fixture
  generation are in `file_picker/bench/README.md`; scratch fixture cleaned up.
- Historical phase-3/4 file-query and phase-7 line timings remain labelled headless,
  not newly measured live performance. Owner ranking examples, target dataset and
  responsiveness budget remain unresolved; long-query/4 KiB-path stress, live
  input-to-screen/p99/peak-RSS measurement and scheduling acceptance remain pending.
- **Phase 5:** land shared floating overlay compositor and command-palette migration,
  then wire yielded work/polling, focus/input/paste/cursor capture, three-row minimum,
  resize/zen, focus restoration and late-paste/event isolation. No duplicate float.
- **Phase 6:** land actual multi-buffer existing-file open/activation API with path
  identity, dirty-buffer/undo/session retention, failure/focus and stale-document
  diagnostic/highlight policies. Do not adapt to startup create-empty opening.
- **Phase 7 remaining:** floating host integration, controller-transition validation,
  viewport reveal, nonconflicting binding/catalog entry and live unsaved/Unicode
  jump/cancel checks. Buffers are not required for this current-document feature.
- **Phase 8 remaining:** phase-5/6 integration plus real open-at-location, validation
  against opened/dirty contents and byte-to-navigation conversion; visible failure
  on changed/removed/unsupported files rather than creation/blind jumping.
- **Phase 9 remaining:** once prerequisites land, extend terminal smoke for actual
  open/type/select/cancel/accept, dirty-buffer revisits/failure recovery, zen/tiny/
  resized terminals and late paste/events; record human visual review separately.
  No claim that the file-picker release, line picker or project search is shipped.
  Human owns branch reconciliation and all Git/GitHub publication.

## Scheduling summary

| Work | Can finish before multiple buffers? |
| --- | --- |
| Phase 1: contracts | Yes |
| Phase 2: scope and discovery | Yes |
| Phase 3: matching | Yes |
| Phase 4: picker model and tile | Yes |
| Phase 5: floating integration | Yes, after floating work; test acceptance only |
| Phase 6: real file opening | No |
| Phase 7: current-document fuzzy lines | Yes |
| Phase 8: project content search | Provider/UI yes; cross-file acceptance no |
| Phase 9: release verification | Independent checks yes; full acceptance no |

Recommended sequence: establish contracts first; discovery and matching can then
progress independently; build the picker UI and floating integration; connect
real opening when the tabs/buffers API is available. Current-document line search
can proceed while that integration is blocked. The first file-picker release is
complete after phases 1–6 and their applicable phase-9 checks; content-search
phases are subsequent features.
