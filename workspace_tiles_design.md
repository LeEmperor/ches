# Ches tile system, workspace, and supporting views

Status: phases 1–5 (geometry, allocation, vertical status rendering, runtime
workspace integration/controls, and shared feedback lifecycle) implemented and
software-verified and human-accepted (2026-10-04). Phase 5 and the carried-over
status presentation/workspace interaction checks from phases 3–4 are accepted.
Phase 6's read-only problems view is software-complete / human-feedback-pending.
Phase 7's interactive problems pane is also software-complete / human-feedback-pending.
Phase 7A's shared tile host (`tile/`, `ches_tile`) with problems migrated onto it
and an error-free demo report fixture is software-complete and human-accepted
(2026-10-05). Phase 7B's shared rounded shell, padding, gaps, and revised band
height are software-complete and human-accepted (2026-10-06), with frames drawn on
the backdrop. Phase 7C's shared read-only text cursor, selection, and copying is
software-complete / human-feedback-pending (2026-10-06). History views, diagnostic
sources, and the external-view protocol remain unimplemented.

**Direction update (2026-10-05):** This worktree implements a general tile system.
Status and problems are concrete consumers/test cases, not the definition of a
tile. Shared tile plumbing is generalized by phase 7A, shared framing/padding by
phase 7B, and read-only text selection/copying by phase 7C (below; awaiting human
feedback). Phase 6/7 software completion does not imply these later
capabilities exist or that their current presentation is human-accepted.

## Goal and scope

Extend the current single-document layout into a small composable workspace while
preserving Ches's comfortable text placement and zen editing experience.

The wider scope is a **service-agnostic tile foundation** for primary work surfaces
and supporting tools. Shared presentation and interaction should not depend on the
error/problem system, a diagnostic producer, or any particular external service.
Use the working problems view to exercise and migrate that foundation, not as an
API that all future consumers must imitate. Keep the existing single-file editor;
this scope does not itself authorize multiple buffers, a plugin framework, an LSP
client, or a Hardcaml workbench integration.

The first consumer is a **status tile**: move relevant status from a mandatory
bottom row into a compact, independently allocated region. This provides a concrete
way to exercise layout before adding terminals or external application views.

AI-specific workflows live in
[`ai_integration_design.md`](ai_integration_design.md). This document describes the
general foundation, including a future option for displaying computations produced
in another process or on another machine.

## Current implementation

- `screen/geometry.ml` computes one document tile and its text/gutter rectangles
  within an allocation. `compute_in` explicitly chooses status-row reservation;
  the full-screen `compute` wrapper retains the existing bottom status row.
- `screen/workspace.ml` allocates stable document/status cells using a requested
  two-leaf split plus a bottom band shared side by side by the requested minor views
  (`Pane_id.Minor of View_id.t`), with compact fallback. Side-by-side panes are
  separated by a one-cell backdrop gap (phase 7B). `Ui_state` derives effective
  geometry from requests/zen state; `Frame` composes the document, status, and each
  minor view's adapter rendering.
- `tile/` (`ches_tile`, phase 7A) is the service-agnostic foundation: `View_id`,
  `Spec` (role and capabilities), `Navigation` (shared list motions, key-based
  selection, scroll offsets), and `Host` (focus, capture precedence, pending
  prefix, notice, and paste owner). It depends only on `core` and `ches_input`.
- `screen/ui_state.ml` owns one controller, layout preferences, scroll state,
  animation, one `Host.t`, and the minor views' adapter states. It is the assembly
  point that dispatches host decisions to `Problems_tile` or `Report_tile`.
- `screen/status_field.ml` defines semantic field IDs and priority/fitting metadata.
- `screen/status.ml` produces mode, filename, dirty, message, pending-key, and
  position fields, then renders them for a row, border title, or allocated vertical
  status cell.
- `ui/editor_view.ml` renders screen frames through Bonsai and adapts UI events.
- `error/error.ml` owns the shared notification/problem reducer; the controller
  translates operation outcomes into typed updates. This semantic state exists
  independently of any tile's visibility or lifetime.
- `screen/problems.ml` renders problems; `screen/problems_tile.ml` is the problems
  adapter (filter, identity selection, details, and acknowledge/inspect/jump
  actions); `screen/report_tile.ml` is the static, error-free fixture;
  `screen/tile_text.ml` holds shared cell-exact rows/wrapping; and
  `screen/tile_shell.ml` (phase 7B) is the shared shell: rounded frame, labels set
  into the borders, padding, focus accent, and size degradation, for minor views
  and dedicated status. Minor views have no text cursor/Visual selection/yank yet. Detail scrolling is available only when detail
  rows exceed the viewport; `Details 1-4/4` means there is nothing further to scroll.
- `app/demo_problems.ml` supplies opt-in, session-local navigation fixtures. It is
  not a general tile content model or a real diagnostic producer.

These boundaries are useful. Extend them with workspace composition rather than
putting layout or external-process concerns into core editing commands.

## Vocabulary and ownership

Use these conceptual distinctions; final OCaml module/type names should follow the
existing implementation:

| Concept | Responsibility |
| --- | --- |
| Document/buffer | Text, file identity, revisions, dirty state, edit history |
| Document view | A view of a document: cursor, selection, scroll, display preferences |
| Pane/tile | Stable view identity, allocated rectangle, shared shell, visibility, focus/input behavior |
| Tile content/adapter | A consumer's presentation data and semantic actions, independent of its shell |
| Major/minor role | Workspace role and default policy, not a content type or capability restriction |
| Session/source | Terminal process, conversation, or external data source independent of visibility |
| Workspace | Layout, focused tile, workspace commands; document/session registries when needed |

A status display is pane content, not an editable text buffer. The same is true of
a dashboard. Avoid forcing all pane contents through editor commands.
Read-only content may still support a text cursor, movement, Visual selection, and
copying. Restricting mutation is not a reason to restrict inspection or yank.

The current editor/controller ownership may couple document and view state. Do not
require a complete multi-view document refactor for the first status tile. Preserve
one document view initially; split shared document state from view-local state when
introducing multiple views of the same document.

## Layout model

A split tree is a reasonable initial foundation:

```text
Workspace
  horizontal split
    document pane
    vertical split
      companion pane (future)
      status pane
```

Leaves reference stable pane IDs; branches specify orientation and sizing intent.
For the first milestone, expose just a document plus a status region rather than
requiring a general-purpose interactive layout editor.

Principles:

- Store requested dimensions separately from effective, clamped geometry.
- Allocate rectangles in terminal display cells.
- Give panes preferred/minimum sizes and a deterministic compact-layout policy.
- Preserve the document's preferred width and adjustable comfortable placement.
  Do not force text to fill every available cell.
- Permit the companion/status region on either side of the document.
- Wider terminals should not automatically open new panes.
- Support hide/restore and zoom/restore without destroying underlying state.
- Recompute geometry on resize; tolerate tiny and zero-sized allocations.

Have workspace allocation produce each pane's outer rectangle. Pane-local layout
then derives content, borders, and decorations from it. Rendering, clipping,
scrolling, cursor placement, and eventual hit testing must share this geometry.
Document geometry is already pane-relative following phase 1; preserve nonzero
origins when sharing shell geometry. Treat the existing edge-to-edge problems
strip and its six-row ceiling as prototype policy, not a permanent minor-tile style.
Future allocations must budget for frame, inset padding, titles/footers, and a useful
content viewport; do not add chrome on top of six rows and accidentally leave no
room to inspect content. Requested/effective geometry and compact/zen restoration
remain separate.

## Input, focus, and lifecycle

- Route normal input to the focused interactive pane.
- Handle workspace navigation at one clear boundary, with documented precedence.
- Show focus in pane decoration and expose a dependable way to leave input capture.
- Only the focused pane supplies the terminal cursor.
- Keep pending document key sequences from leaking across focus changes; define
  cancellation explicitly.
- Treat a paste as one routed interaction, rather than allowing its pieces to
  land in different panes after a focus change.
- Background events can update hidden panes/sessions without changing focus.
- Hiding a pane, closing a view, and terminating its source are different actions.
- Shared routing dispatches content-adapter actions; it does not call problem
  acknowledgement/resolution, file IO, or source lifecycle code itself.
- Text-oriented read-only tiles can own a terminal cursor for selection when that
  capability is introduced. Phase 7's hidden-cursor policy is a prototype, not a
  requirement for all supporting views. There is still only one cursor owner.

For the first milestone, the status pane can be non-focusable. It observes the
active document and workspace rather than participating in text input.

## First milestone: the status tile

### Purpose

Answer three questions at a glance:

1. Where am I?
2. What is happening?
3. Does anything need my attention?

Initial contents should use existing state:

```text
┌─ Status ───────────────┐
│ EDITOR · NORMAL       │
│ geometry.ml [+]       │
│ 84:12                 │
│ pending: 2d           │
│ Saved                 │
└───────────────────────┘
```

Rows are conditional; this is an illustration, not a requirement to show a pending
command and save message simultaneously.

### Information priorities

| Field | Behavior |
| --- | --- |
| Focus and mode | Always identifiable |
| Active file and dirty state | Persistent; use path shortening when necessary |
| Cursor position / selection size | Current editing context; selection size can follow later |
| Pending command | Visible while pending |
| Active persistence failure / future file conflict | Retained until resolved; acknowledgement clears attention, not the problem |
| Routine feedback | Brief, with a future message history if useful |
| Project / branch | Later, when workspace/project state exists |
| Jobs / tests | Later; identify which run or revision a result describes |
| External source / agent state | Later, supplied by the relevant session adapter |

Start with current fields; do not make Git, diagnostics, jobs, or AI prerequisites.
If persistent error behavior differs from current message handling, implement it
explicitly rather than assuming the new presentation supplies it.

### Presentation and fallback

- Reuse semantic status fields; add a vertical presentation alongside row/title
  rendering. Existing left/right placement metadata is row-specific and need not
  dictate vertical ordering.
- Keep filename/dirty and essential mode cues near the document where useful.
- A status tile can reclaim side space on a wide display, but may cost more useful
  area on a narrow one. Collapse it to compact inline/row feedback when necessary.
- Zen mode may hide the dedicated tile, but must retain essential mode, pending
  command, and failure feedback.
- Preserve requested layout across shrinking and re-expanding the terminal.
- Avoid unnecessary animation and continuously changing metrics.

### Acceptance criteria

- A document and status tile render correctly in independently allocated rectangles.
- Moving/resizing/hiding the status tile does not edit text or alter undo history.
- Document scrolling and terminal cursor coordinates stay correct with pane offsets.
- Existing status fields remain meaningful, including pending commands and errors.
- Small terminals retain usable editing and essential feedback without exceptions.
- Returning to zen and restoring the workspace preserves document placement intent.
- Geometry and event routing remain testable without Bonsai or a real terminal.

## Future extension: externally computed views

### Motivation

The owner works on HFT/FPGA trading projects with demanding computation and
dashboard requirements. Those computations should run independently; Ches can be
a presentation client for their results.

Separate three possible boundaries:

1. **External computation, local presentation:** a producer sends metrics, table
   rows, or chart samples; Ches lays them out and renders them.
2. **External layout, local composition:** a producer sends a bounded cell grid or
   drawing description; Ches validates, clips, and composites it into a pane.
3. **Remote pixel/video rendering:** a producer sends images or video. This requires
   graphics/backend support beyond the current terminal-cell renderer and is a
   substantially different feature.

The first is simplest and adapts naturally to local styles and sizes. The second
matches the idea of piping precomputed frames into Ches. Neither makes a terminal
dashboard a hard-real-time display or part of a latency-critical trading loop.

### Recommended initial boundary

Start with a read-only external view, complete snapshots, and a local process or
Unix-domain socket. Separate transport from the pane/source interface so a remote
connection can be added later.
Read-only describes producer mutation permissions, not local inspect/copy ability.
An adapter may supply selectable text through shared tile interactions without
turning local cursor movement or yank into commands sent to the producer. A raw
cell/grid view must explicitly advertise text/copy metadata if that capability is
supported; do not fabricate an editable buffer for arbitrary frames.

Conceptual flow:

```text
compute engine -> telemetry/snapshot publisher -> bounded transport
                                                   |
                                             source adapter
                                                   |
                                        latest snapshot for pane
                                                   |
                                           Ches compositor
```

The compute engine must not wait for Ches. Keep publishing off its critical path,
and specify bounded/drop behavior at the producer as well as the client. A blocked
pipe or TCP writer can otherwise backpressure the computation despite process
separation. Producer-owned ring buffers, aggregation, or a separate publisher are
possible implementations depending on the existing application.

Send display-rate summaries rather than every market event or internal update.
Choose a configurable display cadence appropriate to the view and terminal; measure
it rather than promising a particular frame rate. Ches still pays for decoding,
validation, composition, and terminal output.

### Protocol considerations

A future protocol should define:

- Version, source/session identity, and capabilities.
- Frame dimensions, bounded payload sizes, and supported cell/style representation.
- Sequence numbers and explicit snapshot versus delta semantics.
- A local receipt time for freshness; producer timestamps may help, but clocks on
  separate machines cannot be assumed synchronized.
- Resize notifications with a size generation, so late frames for an old size can
  be recognized, clipped, or discarded.
- Connecting/live/stale/disconnected states; keep the last good frame visibly stale
  rather than presenting it as current.
- Reconnection and full-snapshot recovery.
- Optional input messages and acknowledgements only when interaction is introduced.

For cell frames, specify Unicode display width, wide-character continuation cells,
style encoding, and clipping. Accept structured data, not arbitrary terminal escape
sequences written to Ches's host terminal. A cell-frame pane is distinct from a
terminal-emulation pane even if both eventually display grids.

Start with self-contained snapshots: a bounded latest-value slot can replace an
older unrendered snapshot. This rule does not work for arbitrary deltas. Deltas
need base sequence IDs and a resynchronization path; missing a required delta must
trigger a full snapshot rather than silently corrupting the view.

Do not use latest-value dropping for durable events or logs. Aggregate them
upstream, maintain a separately bounded event channel with explicit overflow
behavior, or retrieve history from the authoritative source.

### Scheduling and isolation

- Network/process reads run asynchronously outside the editor transition path.
- Bound decoding work and payload allocation; limit source update rates and history.
- Coalesce updates so one busy source cannot monopolize the UI event loop.
- A hidden pane can reduce display work without implicitly terminating its source.
- External-source failure should leave the document usable and show source status.
- Keep immutable/owned frame snapshots at the boundary; shared-memory optimization
  would require explicit lifetime and synchronization rules.
- Remote access later needs an authenticated transport and explicit endpoint
  configuration; a local prototype is not automatically a safe network service.

Interactive external views add command routing, reconnect semantics, and the risk
of duplicate commands. Design them separately from read-only observation rather
than replaying UI actions implicitly after reconnect.

### Relative difficulty

| Capability | Relative scope |
| --- | --- |
| Status pane backed by existing local state | Smallest useful workspace milestone |
| Read-only external metrics snapshots | Moderate, once panes and asynchronous sources exist |
| Complete external terminal-cell frames | Moderate to substantial: frame contract and geometry matter |
| Remote transport and reconnection | Additional protocol/lifecycle work |
| Incremental frames and interactive remote applications | Substantial synchronization and input work |
| Arbitrary CLI embedding | Substantial terminal-emulation work, a separate adapter |
| High-rate pixel/video streaming | Different rendering backend and performance scope |

These are relative assessments, not delivery estimates. Benchmark representative
payloads before choosing binary encoding, compression, shared memory, or deltas.
For many dashboards, aggregation and bounded refresh offer more benefit than a
complicated renderer protocol.

## Phase-based implementation

Phases 1–5 complete the status-tile milestone. Each phase is intended to be a
separate implementation-agent assignment. Give the agent this document and its
phase number; it should inspect the current code and previous phase outcomes before
implementing. Module names below are starting points, not prescribed new APIs.

Execute phases 1–5 in order. Keep the existing single document/controller;
follow-on phases 6–10 cover problems/history views, interactive companion panes,
and diagnostic sources according to their stated dependencies. The 2026-10-05
direction adds phases 7A–7C after the existing phase 7: extract the common foundation,
standardize tile presentation, then add shared read-only text interaction. Keep
phase numbers and completed-phase records intact; do not restart phases 1–7 or
silently require their old implementations to already satisfy the new scope.
Multi-view documents
remain outside this milestone. Each phase should leave the application buildable and usable.

### Assignment and completion contract

For every phase, the implementation agent should:

- Implement the stated scope and follow the repository's existing conventions.
- Add a small, focused suite of expect tests for meaningful new behavior, with other
  checks only where needed. Favor observable geometry, rendering, and state
  transitions over tests that merely repeat implementation details.
- Run the relevant tests and required repository checks. Report what actually ran,
  its results, and any checks that could not be performed.
- Record implementation choices and deviations in this document so the next agent
  inherits concrete decisions rather than inventing a competing policy.
- Finish with a handoff summarizing the changes, software verification, unresolved
  issues, and whether human testing is required.

Software completion and human acceptance are distinct. For phases with new
human-facing interactions, the agent's handoff should explicitly say, once the
software checks pass: **"Implemented and tested from the software side; human use
and feedback on the feel of the feature are still needed."** Include a short,
concrete manual checklist and leave human acceptance pending until the owner
provides feedback. Automated checks or an agent's terminal smoke check do not
substitute for that feedback.

Internal-only work does not require a human acceptance gate merely because it is
part of this project. For example, a text-cache backend can be accepted through
software verification. Below, geometry and allocation are verified internally;
their user-visible effects receive human testing when the workspace is integrated.

Before phase 2, record the initial allocation and sizing policy, following the
owner's placement/sizing direction below. Before phase 3, record the
vertical field ordering and essential-feedback priorities. Before phase 4, agree
on the initial controls and zen/restore behavior. Phase 5 now records the initial
feedback retention, acknowledgement, and resolution policy. An agent should raise
material unresolved policy choices rather than silently treating its preferences
as requirements.

### Phase 1 — Pane-relative document geometry

**Depends on:** no earlier phase.

**Scope:** Generalize document geometry to an allocated rectangle, including
nonzero origins. Make status-row reservation an explicit layout policy rather than
an unconditional terminal-wide subtraction. Keep the existing full-screen layout
as the default caller behavior.

**Starting points:** `screen/geometry.ml`, its callers, and existing geometry tests.
Inspect rendering and cursor consumers in `ui/editor_view.ml` as necessary.

**Acceptance criteria:**

- Document outer, text, gutter, and decoration rectangles respect the allocation.
- Scrolling, clipping, and terminal cursor coordinates account for pane origins.
- Tiny and zero-sized allocations are handled without exceptions.
- Focused expect tests cover offset allocations, explicit status reservation,
  constrained sizes, and preservation of the existing full-screen layout.

**Human testing:** Not required for this internal refactor. User-visible placement
and cursor behavior will be exercised in phase 4.

#### Phase 1 completion and handoff (2026-10-04)

- Added `Geometry.compute_in ~allocation ~reserve_status_row`. All document,
  gutter, text, status, and title rectangles use terminal coordinates, including
  nonzero origins. Width/offset preferences are interpreted inside the allocation;
  negative dimensions normalize to zero without changing requested preferences.
- Kept `Geometry.compute` and existing UI-state queries as full-screen wrappers
  with one reserved status row. Added `Ui_state.geometry_in`, `fitted_scroll_in`,
  and `cursor_position_in` for one shared allocation/status policy. Scroll remains
  document-relative; the terminal cursor adds the viewport origin.
- `Frame.render` accepts an optional allocation and explicit status reservation,
  defaults to the original full-screen behavior, clips allocations to screen bounds,
  and leaves rows outside the document/status allocation as backdrop. Pane-mode
  smear cells clip to the text viewport. The Bonsai adapter already consumes frame
  coordinates directly and required no changes. Input transitions remain full-screen
  until workspace integration; no controls, pane registry, or allocator were added.
- Added seven focused expect tests in `screen/test/test_pane_geometry.ml`: offset
  geometry, status reservation, tiny/empty/negative dimensions, bounds and default
  compatibility, backdrop placement, Unicode scrolling/clipping, translated bordered
  rendering (including title/gutter/status/cursor), and screen-edge intersections.
- Verification prerequisite/deviation: existing screen/theme tests referenced
  document-style constructors removed by the earlier style refactor. Migrated their
  assertions to `Style.document`/overlay checks. Restored human-readable spacing in
  `Style.to_string_hum` for nested mode values so existing frame snapshots remain
  unchanged. No editing behavior changed.
- Passed, using `opam exec --switch=5.2.0+ox --`: `dune build` and the complete
  `dune runtest` suite. `git diff --check` also passed.
- Ran `scripts/smoke.sh`: it completed but exited 1 with five cursor assertions
  failing during scrolling/counted movement/document motions. Failure captures show
  the smear animation running and the terminal cursor hidden; those immediate
  assertions do not wait for cursor restoration. Other checks, including edit/save,
  resize, layout placement/restoration, and terminal restoration, passed. This
  smoke-test synchronization gap is not claimed as verified or fixed by phase 1.
  Screens were saved to `/tmp/ches-smoke-screens.WbL5hA`.
- Phase 1's internal software acceptance criteria are satisfied; no human acceptance
  gate is required. Offset panes are tested headlessly, not exposed interactively.
  Phase 4 must exercise their visible placement/cursor behavior. Allocation choices
  were subsequently resolved by the owner's direction and phase 2 policy below.
  No commits or Git-state changes were made.

### Phase 2 — Minimal workspace allocation

**Depends on:** phase 1 and recorded initial allocation/sizing policy.

**Scope:** Introduce stable pane identities and workspace rectangle allocation for
one document and a non-focusable status region. Status is content assigned to a
layout cell, not an inherently left/right sidebar: its allocation must follow that
cell wherever it is placed. Represent requested placement and dimensions separately
from effective geometry. Support deterministic
compact fallback and restoration after resize. Use a minimal layout representation
that can grow toward the split-tree model; a general interactive layout editor is
outside this phase.

**Starting points:** `screen/geometry.ml`, layout preferences in
`screen/ui_state.ml`, and a workspace allocation module if appropriate.

**Acceptance criteria:**

- Allocated rectangles remain in bounds and do not overlap.
- Status allocation follows its assigned cell, including nonzero origins;
  representative placements and constrained allocations follow the recorded policy.
- Shrinking and expanding restores requested layout rather than retaining clamped
  dimensions; wide terminals do not independently enable additional panes.
- Document preferred width and comfortable placement remain expressible.
- Focused expect tests cover allocation, compact fallback boundaries, and resize
  restoration without Bonsai or a real terminal.

**Human testing:** Not required for the allocator alone. Actual space balance and
fallback feel will be assessed in phase 4.

#### Phase 2 allocation policy

- Use a two-leaf split: horizontal (side by side) or vertical (stacked), with a
  stable pane identity naming the first leaf. Status content is independent of
  orientation/order; left, right, above, and below are all supported. No split-tree
  editor or interactive controls are part of this phase.
- Requested visibility defaults to off, preserving today's full-screen document and
  bottom-row feedback. The initial split request is horizontal, document first,
  status size 28 cells. A stacked layout can request an appropriate row count;
  requested size is along the split axis, not intrinsically a width.
- Simple internal minima: document allocation 16 columns by 1 row; status allocation
  8 columns by 3 rows. These are permissive allocation guardrails, not guarantees
  that every field or decoration fits. Vertical presentation will prioritize content
  in phase 3. Clamp the requested status size between its axis minimum and the space
  left after the document minimum; no divider/gap cells are allocated.
- If both minima cannot fit, omit the dedicated status allocation, give the document
  the entire workspace, and reserve its bottom row for compact feedback. Hidden
  status uses the same compact presentation. With a dedicated status cell, do not
  reserve a document status row. Empty/negative dimensions normalize safely.
- Effective allocation is derived without modifying the request. Resizing restores
  visibility, split order/orientation, and requested size automatically; extra space
  never enables an unrequested pane. Document width/offset preferences remain
  independent and are applied within the allocated document cell.

#### Phase 2 completion and handoff (2026-10-04)

- Added `screen/workspace.ml`/`.mli` with stable `Pane_id.Document`/`Status`, a
  two-leaf `Split` request (axis, first identity, requested status size), independent
  workspace `Prefs`, allocated `Pane` rectangles, and `Pane.focusable`. Only the
  document is focusable; allocation does not create or own document/session state.
- `Workspace.allocate` implements the recorded policy for arbitrary workspace
  origins and horizontal/vertical ordering. It returns disjoint document/status
  rectangles plus an explicit compact-row reservation flag. There is no synthetic
  status pane when hidden or constrained; requested settings stay untouched.
- `Workspace.document_geometry` bridges allocation to phase 1's pane-relative
  geometry, preserving independent document width, offset, and full-width intent.
  No changes to core editing, input routing, `Ui_state`, the Bonsai adapter, or
  runtime frame composition were needed. Workspace integration remains phase 4.
- Added six focused expect tests in `screen/test/test_workspace.ml`, covering all
  four placements at an offset origin, exact fallback boundaries on both axes,
  clamping, shrinking/expanding and hiding/restoring, opt-in visibility on wide
  displays, document placement restoration, and tiny/negative dimensions. A bounded
  allocation sweep also checks non-overlap, complete workspace coverage, identities,
  and focusability across requests and constrained sizes.
- Passed: `opam exec --switch=5.2.0+ox -- dune runtest` (complete suite),
  `opam exec --switch=5.2.0+ox -- dune build`, and `git diff --check`.
  No terminal smoke test was rerun: this is an internal-only allocator with no
  application integration, and phase 1's animation-related smoke synchronization
  gap remains unresolved. No manual acceptance is required for this phase.
- Phase 2 software acceptance criteria are satisfied. The only sizing choices are
  the simple recorded internal defaults; a general split tree and layout controls
  were deliberately not added. Vertical field ordering and limited-space priorities
  were subsequently approved and recorded in phase 3. Phase 4 still needs human feedback
  on actual cell placement, presentation, and fallback feel. No commits or other
  Git-state changes were made.

### Phase 3 — Vertical status presentation

**Depends on:** phases 1–2 and recorded field ordering/priorities.

**Scope:** Add a vertical renderer for existing semantic status fields within an
arbitrary pane rectangle. Specify conditional rows, shortening/truncation, and
priority when space is limited. Keep row/title presentation available for compact
feedback. This phase delivers the renderer; application integration follows in
phase 4.

**Starting points:** `screen/status_field.ml`, `screen/status.ml`, and their tests.

**Acceptance criteria:**

- Mode, active file/dirty state, position, pending commands, and current messages
  render meaningfully within the available rectangle.
- Vertical ordering is explicit rather than inherited accidentally from row-specific
  left/right metadata.
- Output clips correctly, including narrow and zero-sized allocations and Unicode
  display widths using the project's existing conventions.
- Focused expect tests cover representative full and constrained presentations,
  conditional fields, and priority behavior.

**Human testing:** Required for the presentation, deferred until it is available in
the running application in phase 4. Renderer tests establish software correctness,
not readability or visual comfort; carry this pending check into the handoff.

#### Phase 3 presentation policy (approved 2026-10-04)

- Full vertical order: mode, filename with dirty marker, position, pending keys
  when present, message when present. Absent fields consume no rows. Filename and
  dirty state share one row; a dirty marker still has its own row if no file exists.
- With fewer rows, choose mode first, then errors, pending keys, dirty/file context,
  position, and routine feedback. Display the chosen rows in the full vertical order,
  not priority order. A clean filename has lower priority than dirty/file context
  but still precedes position. Ignore row-specific left/right placement metadata.
- Render content rows without an extra border/title/padding requirement; this lets
  status use any allocated cell, including shallow stacked cells. Preserve semantic
  styles and pad every output row to its allocated display width; unused rows are
  blank status rows. The renderer owns no terminal cursor.
- Shorten filenames from the left using the existing `<` marker and keep their tail.
  Reserve room for `[+]` before fitting a filename. Other text keeps its start using
  `>` when cut; mode trims the row badge's outer spaces and keeps its initial letters
  on very narrow cells. Preserve the dirty style even when its marker must be cut.
  Pending keys retain their existing text without a label taking scarce width.
  Dirty, pending, and error truncation markers retain their semantic styles even
  when the allocation is only one cell wide.
- Messages keep their current error/warning/info styling and urgency metadata.
  This phase changes presentation only, not error retention or acknowledgement.

#### Phase 3 completion and handoff (2026-10-04)

- Added `Status.vertical ~rect fields` and `Status.Tile.t` in `screen/status.ml`/
  `.mli`. The result preserves the allocation origin and supplies pane-local rows
  of exact display width/height, ready for composition at that origin in phase 4.
  Negative dimensions normalize to zero; no surrounding backdrop, borders, or
  terminal cursor are supplied by this renderer.
- Implemented the approved full ordering and independent height priorities. The
  filename/dirty row reserves dirty-marker width before shortening the path; omitted
  fields consume no rows and unused space is padded. Existing semantic fields and
  span clipping handle Unicode, escaped controls, and styles without adding a new
  status-field representation. Error urgency uses existing message priority metadata.
- Existing `Status.render` row/title behavior and field production are unchanged.
  No runtime UI integration, layout controls, or message lifecycle changes were
  introduced; error retention/acknowledgement remains phase 5.
- Added eight focused expect tests in `screen/test/test_vertical_status.ml` covering
  full/constrained presentations, conditional fields, row priorities, routine vs
  error feedback, narrow-cell semantic styles, Unicode/combining characters, current
  UI-generated dirty/pending/error fields and Insert mode, and empty allocations.
  A bounded width/height sweep verifies exact cell widths, origin preservation, and
  control escaping. Scrambled inputs demonstrate independence from input order and
  horizontal placement/fitting metadata.
- Passed: `opam exec --switch=5.2.0+ox -- dune runtest` (complete suite, including
  unchanged row/title/frame expectations), `opam exec --switch=5.2.0+ox -- dune build`,
  and `git diff --check`. No terminal smoke check was run for this unintegrated
  renderer; phase 1's animation-related smoke synchronization gap remains unresolved.
- **Implemented and tested from the software side; human use and feedback on the
  feel of the feature are still needed.** Human acceptance is pending until phase 4
  makes this presentation available in the running application. Manual checklist:
  inspect Normal/Insert and dirty/file rows on laptop and monitor layouts; inspect
  pending keys, routine feedback, and an error; resize/reposition the status cell and
  judge field ordering, path truncation, readability, and visual balance. Test actual
  colors rather than relying on textual snapshots.
- No implementation deviations or software acceptance blockers remain for phase 3.
  Before phase 4, agree on controls and zen/hide/restore behavior; carry forward the
  presentation review and smoke synchronization gap. No commits or Git-state changes
  were made.

### Phase 4 — Workspace integration and controls

**Depends on:** phases 1–3 and recorded controls/zen restoration decisions.

#### Phase 4 controls and restoration policy (approved 2026-10-04)

- Normal-mode `Space v t` toggles requested status visibility. `Space v p h/l/k/j`
  places status left/right/above/below and enables its requested visibility.
  `Space v p -/+` changes its requested size by two cells (`=` aliases `+`). Sizes
  are session-local, constrained to the allocator's axis minimum through 500 cells.
  Keep separate side-by-side width (initially 28) and stacked height (initially 6),
  restoring each on axis changes. Size controls do not implicitly show hidden status.
- `Space v z` toggles zen: suppress the dedicated cell while retaining compact
  bottom-row feedback and unchanged document placement preferences. Leaving zen
  restores saved workspace intent, subject to normal compact fallback. Status
  controls in zen update saved requests without leaving zen. Hidden-by-default
  visibility and existing document controls (including document-only reset) remain.
- Layout commands remain view actions; no new input destination or focus controls
  are introduced. Paste remains one document interaction. Cancel smear animation
  when workspace intent/zen changes so layout moves do not animate through status;
  clip workspace smear output to the document text allocation.
- Workspace visibility/placement/size and zen transitions preserve a current error
  instead of overwriting it with layout feedback. Other existing message lifecycle
  semantics are unchanged; full retained-error acknowledgement/resolution is phase 5.

**Scope:** Connect workspace allocation and status rendering to UI state and frame
rendering. Implement the agreed controls for showing/hiding and positioning status,
compact fallback, and zen/workspace restoration. The document remains the only
interactive pane and the only terminal cursor provider.

**Starting points:** `screen/ui_state.ml`, `ui/editor_view.ml`, existing layout
commands, and the allocation/status interfaces from previous phases.

**Acceptance criteria:**

- Document and status render together in independently allocated rectangles.
- Layout actions preserve text, undo history, view state, and requested placement;
  effective scrolling may adjust as necessary to keep the cursor visible.
- Resize and zen transitions restore layout intent and retain essential feedback.
- Focused expect tests cover workspace state transitions and integration geometry.
- Perform a terminal smoke check if available and report its actual coverage.

**Human tests — required:**

- Edit and scroll with status on either side; check cursor alignment and comfortable
  text placement.
- Show/hide and reposition status; judge whether the controls feel predictable.
- Shrink and expand the terminal; assess whether fallback occurs at useful sizes.
- Enter and leave zen mode; check restoration and whether essential feedback is
  noticeable without being distracting.
- Assess status readability, field ordering, truncation, and visual balance,
  completing the deferred presentation review from phase 3.

End with the software-complete/human-feedback-pending handoff described above.
Record the owner's feedback and any follow-up changes before claiming human
acceptance.

#### Phase 4 completion and handoff (2026-10-04)

- Added the approved workspace/zen commands to `input/view_command.ml`/`.mli` and
  default bindings in `input/bindings.ml`. The nested placement prefix uses existing
  keymap prefix handling/cancellation; workspace commands reject counts and are
  literal text in Insert/paste. `input/keymap.mli`, README, and CLI help document
  the controls. The prior unknown-binding test now uses `Space v x`, since `z`
  deliberately has a zen meaning.
- `screen/ui_state.ml`/`.mli` own saved workspace preferences, an inactive-axis size
  request, and zen suppression. `workspace` derives effective allocation; geometry,
  scroll fitting, view-scroll commands, cursor coordinates, and frame rendering all
  use the allocated document rectangle. Document preferences and core state are
  untouched by workspace commands. Resizes and zen/hide transitions preserve requested
  layout; axis changes swap saved width/height requests. Workspace changes cancel
  smear animation, and current errors survive those specific layout commands.
- `screen/frame.ml`/`.mli` compose document decorations/content and vertical status
  rows within disjoint rectangles, filling remaining space with backdrop. Only the
  document supplies a terminal cursor. Workspace smear cells clip to its text
  rectangle. Explicit-allocation headless rendering remains available. The existing
  Bonsai adapter already consumes frames/cursor coordinates directly, so it required
  no changes; no focus switching or extra input destination was introduced.
- Added eight expect tests in `screen/test/test_workspace_ui.ml`: all four placements
  and independent size memory; zen/resize restoration; composed frame snapshots;
  editor identity and undo/redo preservation; error/pending feedback through layouts;
  shared Unicode scroll/cursor geometry at normal/tiny/zero sizes; literal paste and
  prefix/count safety; size limits and layout-animation cancellation. Existing
  single-document geometry/status/frame expectations still pass.
- Extended `scripts/smoke.sh` for workspace controls and laptop/monitor-sized captures,
  scrolling/cursor alignment, compact/tiny fallback and restoration, zen updates,
  show/hide, editing/undo/redo/save, and controlled save-error transitions. Converted
  the earlier immediate cursor checks to visible-cursor polling, closing phase 1's
  smear synchronization gap. Per-run tmux socket names now isolate concurrent runs
  from different checkouts; cleanup only touches that run's server and fixtures.
- Verification: `opam exec --switch=5.2.0+ox -- dune build` and the complete
  `dune runtest` suite passed. `bash -n scripts/smoke.sh`, `git diff --check`, and
  `git diff --cached --check` passed. The complete isolated smoke run passed using
  `TMPDIR=/tmp/opencode opam exec --switch=5.2.0+ox -- scripts/smoke.sh`.
  Log: `/tmp/opencode/tiles-phase4-smoke-isolated.log`; colored captures:
  `/tmp/opencode/ches-smoke-screens.dD29qo`. An earlier run failed three assertions
  that expected text beyond the status truncation point (corrected), and a retry
  timed out after shared-server interference (resolved with per-run isolation).
- **Implemented and tested from the software side; human use and feedback on the
  feel of the feature are still needed.** Phases 3–4 human acceptance remains pending.
  Try `Space v t`, place status with `Space v p h/l/k/j`, adjust with `p -/+`, and
  edit/scroll on the laptop and monitors. Shrink/expand; toggle `Space v z` and
  change saved placement while in zen. Judge cursor alignment, text placement,
  controls, field ordering, truncation, colors, readability, and distraction. Automated
  tmux checks do not establish palette quality, cursor shape, flicker, or comfort.
- No phase 4 software blockers remain. At this handoff, phase 5 still needed agreed error
  retention, acknowledgement, and resolution semantics (now recorded in phase 5
  below); this phase's transition-specific error safeguard is not a complete
  retained-error lifecycle. Incorporate the owner's
  phase 3/4 feedback when received. No commits were made.

### Phase 5 — Shared feedback state and status-tile acceptance

**Status (2026-10-04): software-complete / human-accepted.**

**Depends on:** phase 4. The feedback direction and initial lifecycle policy below
are recorded from the owner discussion on 2026-10-04. Incorporate any human feedback
already received; keep outstanding phases 3–4 human acceptance visible.

**Scope:** Separate feedback production, lifetime, and presentation. Replace the
single disposable message slot with shared transient-notification and active-problem
state, and connect the existing tile, compact, and zen status presentations to it.
Complete the status-tile milestone without requiring a problems tile or LSP client.

**Starting points:** `core/editor.ml` messages and effect outcomes,
`app/controller.ml`, `screen/ui_state.ml`, status field production/rendering, and
workspace integration tests.

#### Feedback direction and initial policy

The owner wants a Trouble-like problems display eventually, with sources reporting
information independently of whether a tile currently renders it. Use structured
updates into queryable current state. Opening a tile later must show current
problems without replaying an event history. A background service, general event
bus, configurable subscriptions, and event-sourced persistence are not required;
ordinary typed updates and a pure reducer fit the current synchronous application.

Distinguish three concepts:

| Concept | Meaning | Ownership/lifetime |
| --- | --- | --- |
| Notification | Feedback about an action, such as a refused quit or successful save | Interaction or acknowledgement policy |
| Active problem | A continuing condition, such as failed persistence or a diagnostic | Matching recovery or replacement by its source |
| History/log | Past events, including already resolved failures | Bounded retention; deferred to phase 8 |

Severity and lifetime are separate. Error styling does not automatically make a
message persistent. Producers supply structured identity and lifecycle information;
renderers must not infer resolution by parsing human-readable text.

Initial policy for existing feedback:

| Feedback | Lifetime | Clearing behavior |
| --- | --- | --- |
| Failed save or reload | Active problem plus attention notification | Matching successful operation for the same file resolves the problem; acknowledgement clears attention only |
| Quit refused because of unsaved changes | Transient notification | Next completed editor command; dirty state remains independently visible |
| Failed search/motion, empty register, unsupported operation, rejected input | Transient notification | Next completed editor command |
| Save success, layout feedback, keybinding notice | Transient notification | Next completed editor command or newer transient notification |
| Future LSP diagnostic | Source-owned active problem | Source replaces/clears its collection; typing or acknowledgement does not resolve it |

“Completed editor command” includes a dispatched move or edit, but not a pending
prefix, ignored key, animation tick, resize, or layout-only action. If a future
policy specifically says “after typing,” use a successful document edit rather
than any keypress. Routine notifications cannot delete active problems or replace
unacknowledged failure attention.

Acknowledgement means “seen,” not “fixed.” Initial control: idle Normal-mode Escape
acknowledges failure attention while retaining its existing search-highlight
clearing behavior. Escape first leaves Insert/Visual mode or cancels a pending
command/count/search; those uses do not also acknowledge. A further idle Escape
can acknowledge. Do not change saved state or retry an operation on acknowledgement.
For a minimal initial interface, acknowledge the currently presented problem and
use a deterministic order for other unacknowledged problems.

A successful save resolves only the corresponding save problem for the same file;
a successful reload resolves the corresponding reload problem. Unrelated success
must not clear either. Key active problems by source, operation/kind, and resource;
repeated failure updates the existing entry and renews attention, including after
acknowledgement. Keep save and reload failures distinct. Explicit destructive
resource replacement/closure must have a documented cleanup rule when introduced.

Keep shared feedback state outside individual tile instances. Hiding, resizing,
repositioning, destroying a view, or entering zen cannot clear it. The editor and
controller report semantic outcomes; the UI/application feedback reducer owns
presentation attention and transient lifetime. Preserve the current single-editor
architecture; do not require a document registry refactor.

Before the problems tile exists, show unacknowledged failure text prominently in
status. After acknowledgement, retain a compact unresolved-problem indicator and
provide a command to show the retained details again. Reopening details must not
retry the operation. When multiple problems exist, the indicator includes their
count and the details command must make each reachable. Record its binding during
implementation. This prevents acknowledgement from making an unresolved failure
inaccessible. All status presentations consume the same state and policy.

**Work items:**

- Introduce structured notification/problem updates with source, severity, scope,
  and problem identity where applicable. Keep final module/type names idiomatic.
- Support posting transient feedback, setting/updating a problem, acknowledging
  attention, and resolving a matching problem. Represent active state separately
  from transient display and from future history.
- Adapt existing producer paths without matching message strings. Remove the
  workspace-command-specific error-preservation workaround once shared policy
  supplies the behavior.
- Define deterministic attention ordering and bounded visible summaries. Maintain
  existing mode/pending priorities and bounds safety in tiny allocations.
- Leave history storage, navigable problems content, source collection replacement,
  async source scheduling, and actual LSP integration to the phases below.

**Acceptance criteria:**

- Save failure → move/edit → keybinding warning → layout/compact/zen transitions
  preserves the active problem and unacknowledged failure attention.
- Acknowledgement clears attention but leaves the unresolved indicator and
  retrievable details; it does not change dirty state. Repeated failure renews
  attention without duplicating the problem.
- Matching success resolves its problem; unrelated success and transient feedback
  do not. Multiple problem identities coexist and can be inspected/acknowledged.
- Escape precedence, transient clearing, and essential mode/pending feedback are
  covered by a small suite of lifecycle and layout regression expect tests.
- Relevant software checks and an available terminal smoke check pass; report
  remaining gaps rather than treating them as verified.

**Human tests — required:** Trigger routine feedback, refused quit, and controlled
save/reload failures. Continue editing; switch between tile, compact, and zen;
acknowledge, inspect retained details, retry unsuccessfully, then recover. Assess
visibility, predictable lifetime, Escape behavior, and distraction. Also retain the
short normal-editing/layout comfort check from phases 3–4.

End with the explicit software-complete/human-feedback-pending handoff. The
status-tile milestone is human-accepted only after the owner supplies feedback and
resulting acceptance blockers have been addressed.

#### Implementation and verification (2026-10-04)

- Replaced the starter `error/` placeholders with `Ches_error.Error`, a pure typed
  reducer with structured notification source/scope/severity, problem identities,
  independent active state and attention, matching resolution, and retained inspection.
  It depends only on Core. The controller holds the shared state outside views and
  translates file outcomes by operation and path; no feedback text is parsed.
- Default retained-details binding: **Normal `Space v e`**. Repeating it cycles every
  current problem in stable first-occurrence order, wrapping to the first. Updating
  an existing identity keeps its position. Idle Normal Escape acknowledges the
  inspected problem, or the first unacknowledged problem when no details are selected,
  while retaining search-highlight clearing. Mode exits and pending-input cancellation
  take precedence. Inspection does not retry or renew attention.
- Acknowledged failures retain a compact `[N problem(s): Space v e]` indicator. Multiple
  presented failures include their active count. Rendered text remains cell-clipped;
  mode and pending priorities and zero/tiny-allocation safety remain covered.
  Tile, compact, and zen query the same state; the old workspace-specific error
  preservation branch and UI message slot are removed. Routine feedback can replace
  other routine feedback, while attention remains visible until acknowledged.
- No resource switch/closure exists in the single-editor controller. Creating a new
  controller starts fresh feedback; same-file reload keeps other problem identities.
  A future destructive resource switch must introduce an explicit cleanup update.
- Four lifecycle expect tests cover identity isolation, deterministic inspection,
  selected acknowledgement, repeated failure, independent save/reload recovery using
  real filesystem failures, dirty-state preservation, Escape precedence, ignored keys,
  prefixes, animation, transient clearing, layout transitions, tiny bounds, and
  simultaneous search-highlight clearing. The existing workspace regression now uses
  an active persistence failure, matching the new transient refused-quit policy.
- Verified in the `5.2.0+ox` switch: `dune build`, `dune runtest`, and the extended
  `scripts/smoke.sh` all pass. The terminal test covers editing and keymap notices after
  failure, tile/zen transitions, acknowledgement, retained details, failed retry,
  successful save, and controlled reload failure/recovery. Review captures:
  `/tmp/ches-smoke-screens.Q8peib`; test log: `/tmp/ches-phase5-verified-smoke.log`.
- **Human acceptance remains pending.** The terminal script does not establish palette
  comfort, flicker, distraction, or whether the lifetime and bindings feel predictable.
  Run the human sequence above and the phases 3–4 editing/layout comfort check;
  incorporate owner feedback before marking the status-tile milestone human-accepted.

#### Human acceptance (2026-10-04)

- The owner confirmed routine feedback works correctly, then confirmed the controlled
  persistent save-failure sequence (editing/layout persistence, acknowledgement,
  retained inspection, failed retry, and matching recovery) works.
- The owner subsequently confirmed the remaining reload failure/recovery,
  editing/scrolling and layout/resize/zen comfort, and presentation checks are all
  fine. This completes the deferred phases 3–4 human review as well as phase 5.
- No human acceptance blockers or follow-up changes were reported. The status-tile
  milestone (phases 1–5) is human-accepted. Earlier pending handoffs above describe
  the state before this owner review; follow-on phases remain outside this acceptance.

## Follow-on phases — Problems, history, and external sources

These are separate implementation assignments, not additional acceptance gates for
phase 5. Follow the dependencies below; record concrete bindings and interface
choices at the start of each assignment. Apply the same software/human acceptance
contract. Phase 9 can proceed after phases 5–6 independently of phases 7–8;
external cell-frame work remains a separate track from semantic diagnostics.
The semantic work in phases 8–10 remains distinct from the tile foundation. New
history/external UI must use phases 7A–7C's shared contracts rather than copying
the problems-specific capture implementation. Dependency details below distinguish
backend work that can proceed independently from UI integration that needs migration.

### Phase 6 — Read-only problems tile

**Status (2026-10-04): software-complete / human-feedback-pending.**

**Implementation choices (2026-10-04):** Normal `Space v b` toggles a read-only
bottom problems tile; `Space v f` toggles workspace/current-document filtering
(workspace by default). `Space v e` continues cycling all retained details,
including filtered-out and overflow entries. The tile occupies up to six rows
across the workspace width, below the existing document/status allocation.
Its header reports filtered and total counts; overflow reserves a final row
with an explicit hidden-entry count. First-occurrence ordering is retained.
Zen and undersized allocations hide the view without changing its request or
filter. Document/status minima take precedence over the problems tile. Optional
locations are displayed as one-based line/column, not navigation targets.

**Depends on:** phase 5.

**Scope:** Add a Trouble-like view of current active problems. Extend allocation
only as needed to let document, status, and problems coexist; preserve requested
layout and compact/zen fallback. Do not turn the problems view into an editable
text buffer or require interactive focus routing yet.

**Work items:**

- Render shared active problems with source, severity, resource, and location when
  available. Support a simple current-document/workspace filter and deterministic
  ordering; acknowledged problems remain present until resolved.
- Add show/hide controls and a bounded preview with an explicit overflow count.
  Keep phase 5's status details access available for entries beyond the preview.
- Keep problem identity/state independent of each view's visibility and filters.
  Status summaries and problems content must agree after updates and recovery.

**Acceptance:** Test empty/multiple sources, repeated updates, resolution,
acknowledged entries, filtering, overflow, coexistence, and constrained allocations.
Hiding/reopening the tile loses no active state. Human use must assess placement,
readability, density, and whether a persistent bottom problems view is comfortable.

#### Implementation and verification (2026-10-04)

- Added the pure `Ches_screen.Problems` renderer, consuming the same controller
  feedback as status. Filtering and hiding do not acknowledge, resolve, or remove
  problems. Repeated updates keep first-occurrence order. Optional display locations
  are carried by typed `Report` updates; existing file failures remain location-free.
- Workspace allocation reserves a full-width bottom preview of three to six rows
  only when document/status minima fit. Existing requested status placement/sizes
  and document preferences are preserved; zen/compact fallback restores on return.
  The companion remains non-focusable; cursor, editing, paste, and undo stay in the
  editor. No navigation, history, diagnostic collections, or async producer added.
- Four expect tests cover empty/multiple sources, acknowledgement, repeated updates,
  resolution, filters, overflow and retained-detail reachability, hide/reopen, zen,
  coexistence and undo. Bounds checks exercise 4,050 size/position combinations,
  including zero/tiny allocations and Unicode/control text, asserting disjoint panes,
  exact row cell widths, sanitized text, and document-only cursor ownership.
- Verified with `opam exec --switch=5.2.0+ox -- dune build` and `dune runtest`;
  the extended `scripts/smoke.sh` passes. Terminal checks cover acknowledged save
  failures in the tile, filtering, hide/reopen, zen, constrained resize/restore,
  matching save recovery, and reload failure/recovery. Log:
  `/tmp/opencode/tiles-phase6-smoke.log`; review captures:
  `/tmp/ches-smoke-screens.78cKcp`.
- **Software-complete / human-feedback-pending.** Trigger a controlled save failure,
  show the tile with `Space v b`, acknowledge with idle Escape, toggle the filter,
  hide/reopen, resize and enter/leave zen, then retry and recover. Repeat for reload.
  Assess persistent bottom placement, readability/density, editing/scrolling comfort,
  distraction and flicker. Synthetic tests cover multiple resources and overflow;
  the single-file UI currently produces only save/reload failures. Owner feedback
  and any resulting blockers are required before phase 6 is human-accepted.

### Phase 7 — Interactive panes and problem navigation

**Status (2026-10-04): software-complete / human-feedback-pending.**

**Implementation choices (2026-10-04):** Normal `Space v o` shows/focuses the
problems tile; in the tile it returns to the document. Pane keys: `j/k`, `gg/G`,
`Ctrl-d/u` select/scroll; `e` inspects the selected identity in status; `a`
acknowledges only that identity; Enter jumps to a supported current-file location
and returns to the editor. `e` toggles wrapped, scrollable details. Escape first
cancels a pane prefix, then closes details, then returns to the document (without
acknowledgement); Tab returns directly. `Space v` layout commands remain
available, but editor commands cannot run from pane capture. Selection follows
identity across updates; removal/filtering selects the item at the previous index
(the next neighbor, or the last item). Hiding, zen, or a constrained allocation
returns keyboard/cursor ownership to the editor. Paste is routed atomically to
its start owner: a paste begun in the problems pane is rejected, never replayed
as keys or redirected after resize. Display locations are one-based terminal-cell
columns; invalid/out-of-range, missing, and cross-file locations are rejected without
changing dirty state, text, history, or the active problem.

**Depends on:** phase 6.

**Scope:** Introduce focus/routing for the problems tile as the first interactive
companion pane. Add selection, scrolling, detail inspection, and jumping to a
supported document location.

**Work items:** Define workspace-navigation precedence, Escape from input capture,
pending-key cancellation, atomic paste routing, cursor ownership, and return to the
editor. Preserve selection by problem identity across updates; choose a predictable
neighbor when it disappears. Acknowledgement does not resolve a source-owned
problem. Specify safe behavior for unavailable resources and unsupported cross-file
navigation; do not silently discard a dirty document to follow a location.

**Acceptance:** Tests cover routing, updates during selection, missing locations,
focus restoration on hiding a pane, and editing/undo preservation. Human tests cover
navigation, jump/return, keyboard ownership, and visibility in compact/zen layouts.
Multi-document editing is not implicitly required by this phase.

#### Implementation and verification (2026-10-04)

- Added pure identity-based `Ches_screen.Problem_navigation` selection/viewport state
  and problems-pane input capture in `Ui_state`. Configured workspace view bindings
  remain available; editor actions cannot execute during capture. Escape/prefix/detail
  precedence, direct return, hidden/zen/compact focus restoration, and start-owner
  atomic paste routing are explicit. The frontend emits resize reconciliation events
  without persisting a temporary document scroll fit.
- Focus is indicated by `Problems*`, selection by `>`, and the footer reports items
  above/below the viewport or detail row range. Wrapped details preserve whole display
  glyphs where space permits and sanitize controls. The pane owns no terminal cursor
  or editor smear. Selected inspection/acknowledgement target identity, not whatever
  unrelated failure currently has status attention. Updates retain selection/detail
  capture; removal/filtering selects the documented neighbor and closes obsolete details.
- Added validated same-document navigation through the controller/editor, converting
  one-based terminal-cell locations to UTF-8 boundaries with the editor's width mapping.
  TAB/wide glyph interiors select their glyph. Invalid positions, missing locations,
  and unsupported cross-file/unavailable-resource jumps leave text, dirty state, undo,
  cursor, and active problems unchanged. There is no file switching, disk reload, or
  multi-buffer implementation. Version-based freshness checks remain phase 9 work.
- Eight expect tests cover routing, selection during updates/resolution/filter changes,
  scrolling/details, acknowledgement, capture cancellation, configured view bindings,
  pending Normal input precedence, focus return, resizing, atomic paste, UTF-8/TAB jump
  conversion, missing/out-of-range/cross-file targets, and editing/undo preservation.
  Focused list/details bounds are checked in 15,300 allocation/position combinations.
- Verified `dune build` and `dune runtest` in the `5.2.0+ox` switch. Extended terminal
  smoke checks pass, including a two-problem save/reload failure sequence, focus/selection,
  detail capture, acknowledgement, prefix cancellation, missing-location refusal,
  editor-command/paste rejection, resize focus return, preserved undo, matching recovery,
  and empty-list focus. The existing scroll suite also passes after a regression fix.
  Log: `/tmp/opencode/tiles-phase7-smoke.log`; review captures:
  `/tmp/ches-smoke-screens.LEKp6d`. Location jumps and cross-resource behavior are
  synthetic tests only: current runtime file failures do not carry locations.
- **Software-complete / human-feedback-pending.** Trigger save/reload failures, focus
  with `Space v o`, select/inspect/acknowledge, try Enter on a location-free failure,
  cancel a pending prefix, return and edit/undo, then hide/resize/use zen and recover.
  Assess focus/selection clarity, keyboard ownership, detail readability/scrolling,
  placement, distraction, and compact/zen behavior. Human review of phase 6's bottom
  preview remains pending too; neither milestone is marked human-accepted by automation.

#### Opt-in manual navigation fixture (2026-10-05)

- Owner feedback confirms `Space v o` focus works, but ordinary launches may have
  no problems to select, and save/reload failures cannot test location jumps.
- Added `ches --demo-problems PATH` (or `dune exec ches -- --demo-problems PATH`).
  It seeds eight labelled, initially acknowledged DEMO findings with column-1
  locations spread over the opened document. Each uses an isolated `demo/NN`
  namespace so normal file recovery cannot resolve a demo or vice versa. No text,
  dirty state, cursor, or filesystem changes are made by seeding; normal launches
  remain unchanged. Entries are session-local startup snapshots, not live diagnostics.
- Manual sequence: open a multiline file with the flag, `Space v o`, `G`, Enter
  (last line); refocus, `gg`, Enter (first line); refocus, `G`, `e`, then scroll
  the long details with `j/k` or `Ctrl-d/u`. Short/empty files reuse jump locations.
  Restart without the flag to remove demo entries. Human navigation acceptance
  remains pending; this fixture makes that review possible without filesystem failures.
- Verified build and expect tests in `5.2.0+ox`; demo tests cover valid jumps for
  empty/short/Unicode documents, idempotent seeding, unchanged text/dirty state,
  and isolation from real file failures. The extended terminal smoke suite passes:
  demo selection/details, actual first/last-line cursor jumps, unchanged saved bytes,
  and an ordinary relaunch with no demo entries. Log:
  `/tmp/opencode/tiles-demo-problems-smoke.log`; captures:
  `/tmp/ches-smoke-screens.fdsSUo`.

### Phase 8 — Bounded notification history

**Depends on:** phase 5 for history storage; phases 7A–7C for its interactive view.

**Scope:** Make previous action feedback inspectable without mixing it into the
current problems list. Implement history as a second real minor-tile consumer of
the shared shell and read-only interactions, not another problems-specialized pane.

History storage/reducer work may proceed independently of the tile migration.
For the interactive view, reuse generic list/text interaction;
do not model historical events as active problems or borrow their resolution policy.

**Work items:** Record bounded chronological notification/lifecycle history with
source and resource context. Specify the capacity, eviction policy, repeated-event
coalescing, and whether ordinary success/layout notices are included. Clearing
history must not resolve active problems; resolving a problem must not erase its
historical occurrence. Keep history in memory initially; cross-launch persistence
and full diagnostic-snapshot logging are out of scope.
The history adapter owns chronological entry identity and retention semantics;
tile visibility, cursor/selection, copied text, or closing the history view cannot
clear storage or affect active problems. Empty/evicted selections need explicit
adapter reconciliation rather than a global problem-specific rule.

**Acceptance:** Tests cover bounds, ordering, repeated failures, acknowledgement,
resolution, and independence from active state. Human tests cover finding an earlier
failure after its notification disappears and understanding past versus current
problems. History must not grow with every render or animation tick.
Also verify shared frame/padding, read-only selection/yank, and generic focus/paste
routing with history and problems coexisting. No extra history-only shell or input
capture implementation should be needed.

### Phase 9 — Diagnostic collections and asynchronous source lifecycle

**Depends on:** phase 5; use phase 6's view for integration acceptance.

**Scope:** Extend active problems with source-owned diagnostic collections, using a
synthetic asynchronous producer before implementing a language-server client. This
is semantic feedback data, separate from the external cell-frame protocol below.
Do not make diagnostic collections a tile-framework abstraction. Their identities,
severity, acknowledgement/freshness, and source cleanup belong in the feedback/source
layer; the problems adapter projects them into ordinary tile presentation data.
Backend development does not depend on phases 7A–7C, but any new tile-facing API
must follow their agreed boundary, with UI integration on the migrated problems view.

**Work items:**

- Replace collections atomically by source namespace and resource. An empty
  collection clears that source/resource only; independent sources cannot erase
  each other's findings. Do not require producers to assign stable per-item IDs;
  document identity reconciliation for selection and acknowledgement.
- Carry document version/generation and source-session identity. Reject obsolete
  updates where freshness can be established; define stale/unknown presentation
  when it cannot. Typing alone does not prove diagnostics resolved.
- Define source disconnect, restart, resource close, and reconnect cleanup. Do not
  silently present disconnected results as fresh or equate disconnect with success.
- Bound incoming work and coalesce replaceable snapshots while preserving operation
  outcomes. Keep updates responsive without coupling production to tile visibility.

**Acceptance:** Synthetic tests exercise two sources on one file, empty replacement,
out-of-order versions, edits while computing, bursts, disconnect/restart, and hidden
views. Measure input responsiveness under bursts and report the method/results.
Human tests assess freshness indicators and whether rapidly updating lists distract.
No general plugin/subscription framework is required.

### Phase 10 — First language-server diagnostic integration

**Depends on:** phase 9; phase 7 for location navigation.

**Scope:** Connect one concrete language server to the diagnostic collections and
problems/status views. Choose the language/server and launch configuration before
implementation. This phase does not imply completion, hover, rename, code actions,
or a general language-server management UI.

**Work items:** Implement the required process/session and document-synchronization
lifecycle and diagnostic transport for the chosen server. Keep protocol errors and
server failure distinct from source-code diagnostics. Map severity, resource,
range, source, and version context into the shared model. Handle protocol position
encoding explicitly when converting locations to editor positions. Make server
restart and unsupported/missing configuration understandable.
The language-server client reports to the diagnostic/feedback layer, never directly
to shell, focus, or selection state. The problems adapter owns jump/acknowledgement
actions; shared tile infrastructure has no LSP or file-location dependency. Before
adding new UI behavior, complete the shared-shell/routing migration in phases 7A–7B;
use phase 7C's text capabilities rather than reimplementing selection/copying.

**Acceptance:** Controlled integration fixtures cover initial diagnostics, editing
and recovery, location conversion including Unicode, source restart, and stale
results. Human tests use a real project, fix an error, follow a location, and repeat
with problems hidden and in zen. Record server/version and any protocol limitations.

## Other later milestones — Externally computed views

The original external-view track remains independent of the feedback phases above.
Expand each into a concrete assignment before implementation; diagnostics do not
require terminal/cell-frame transport.
Reuse the service-agnostic tile foundation (7A–7B), and 7C where content offers
selectable text. External content need not enter the error system to obtain a tile.
Source failure may separately post feedback without changing ownership of its data.

1. **Read-only external snapshot prototype:** Use a synthetic producer and bounded
   latest-snapshot updates. Exercise bursts, producer exit, freshness, resize, and
   reconnect behavior, and measure typing latency. Human testing is required for
   readability, stale-state feedback, and perceived editing responsiveness.
2. **Concrete external integrations:** Add remote transport or richer frame
   protocols only against a concrete producer. Specify lifecycle and recovery
   semantics before implementation. Reuse the extracted shared routing, not the
   problems-specific phase 7 prototype, if interactive content
   is needed. Require human testing for new visible or interactive behavior;
   internal-only changes can be verified through software checks.

## Decisions still open

### Owner direction for phase 2 (2026-10-04)

- Status must work in whichever layout cell it is assigned to, wherever that cell
  goes. Left/right examples are useful test cases, not a restriction on status
  content or its placement contract. The layout owns the rectangle; status consumes
  it without deciding where it belongs.
- Target the owner's large monitors and laptop. This is a personal project; tuning
  sizing and fallback for other users or a broad range of devices is not a goal.
- Keep cell sizing simple. The previously suggested 28-cell width, 20-cell minimum,
  40-cell document minimum, and 7-row threshold were not adopted. Modest internal
  defaults are acceptable implementation choices to record, not decisions requiring
  extensive sizing design. Retain bounds safety and requested-layout restoration.
- This direction does not require a general interactive layout editor in phase 2.
  Controls and zen behavior remain later decisions. Phase 2 records hidden-by-default
  visibility as its initial internal policy, subject to integration feedback.

### Remaining decisions

- Common shell defaults and compact degradation thresholds are recorded in phase
  7B; their comfort on the owner's laptop/monitors still needs human review.
- Shared read-only text interaction bindings, selection modes, copy destination,
  and update-during-selection policy, as specified in phases 7A–7C below.
- History retention capacity and the first language/server configuration.
- Remaining human feedback on problems layout/navigation and the new shared tile
  presentation/interactions. Status phases 1–5 remain human-accepted; the new
  direction does not retroactively erase that acceptance.
- Whether status follows the focused pane or also retains a pinned document summary.
- First external producer and whether its output is semantic data or cell frames.
- Refresh/freshness requirements and acceptable dropped-snapshot behavior for it.
- Which workspace/session/layout settings should persist across launches.

## Shared tile direction — Major/minor roles and consumer-independent plumbing

### Owner direction and current gaps (2026-10-05)

The owner is happy with the main editor's rounded corners and comfortable inset
placement, but the problems tile currently touches the screen edges and places
list text against them. Supporting tiles should feel like members of the same
workspace, not unframed strips of output. The owner also expects read-only content
to be inspectable and copyable, much like a read-only buffer in a Neovim split.

This worktree's objective is **the tile system**. The error/problem system backs
the first examples and provides useful lifecycle tests; it is not the fundamental
abstraction around which minor tiles should be built. Current problems-specific
capture/selection fields in `screen/ui_state.ml` demonstrate behavior but still
need extraction. No claim is made that phases 6–7 already provide a generic tile
registry, consistent auxiliary chrome, or buffer-style text selection/copying.

### Major and minor tiles

| Role | Intended use | Shared foundation and specialization |
| --- | --- | --- |
| Major | Primary work surface: the current editor; potentially a future Hardcaml report/workbench | Uses common shell/focus contracts; adds rich domain-specific content and interactions |
| Minor | Supporting view: problems, retained details, history, tool output | Uses common shell and reusable list/read-only text interactions; adds a small content adapter |

These are **workspace roles/defaults**, not a mandatory OCaml inheritance tree.
Implement shared composition first; specialize through explicit capabilities and
policy hooks. A major report can be read-only; a minor tool can have an approved
input field. Role alone does not imply editability, focusability, a terminal cursor,
copy/paste behavior, source lifetime, or automatic layout priority. Status may stay
non-focusable while sharing presentation machinery. A detailed view can remain in
its existing tile rather than requiring another tile instance.

All tiles use the same foundation where applicable. Major content may override
presentation/interaction defaults for a concrete need, but may not bypass bounds,
cursor ownership, atomic input routing, or view/source lifecycle guarantees. The
editor remains the only implemented major content type for now. A
`hardcaml-reports` major tile is an example of future specialization, not a newly
authorized integration or an excuse to overgeneralize the first API.

### Boundary and dependency contract

| Layer | Owns | Must not own |
| --- | --- | --- |
| Workspace/tile host | Stable view IDs, requested/effective allocation, role/default policies, focused/captured destination, hide/restore, generic action dispatch | Problems, severity, acknowledgement, diagnostics, file IO, or producer collections |
| Shared tile shell | Outer/frame/title/footer/content rectangles, rounded chrome, inset padding, focus decoration, clipping | Source semantics, problem filtering, resolution, document mutations |
| Shared content interactions | Capability-based list/text movement, viewport, text cursor/selection, yank, pending-input handling, explicit paste policy | Problem-specific identity types, retry/jump meaning, diagnostic freshness, real document dirty/history state |
| Content adapter | Presentation snapshots, opaque item keys and reconciliation policy, semantic actions/capabilities, canonical copy text | Duplicated shell geometry or independent workspace input capture |
| Tool/service/source | Authoritative data, identity/lifecycle, domain operations; feedback reporting where appropriate | Ownership of layout, focus, chrome, or generic selection state |

The problems adapter translates active feedback into rows/details and translates
semantic actions back into selected acknowledgement or validated navigation. The
feedback reducer still owns attention/resolution; the editor/controller still
owns dirty documents and navigation validation. The shared layers must not import
`Ches_error.Error` or require a `Problem.t` to represent content. Application assembly
may depend on both layers to wire them together. An error-free static report/list
fixture must be able to use the same tiles without inventing save/reload identities
or posting notifications to become visible.

View instances own view-local cursor, selection, scroll, and capture state. A
source/session owns its data independently. Hiding, compact fallback, changing
decoration, or closing a view cannot acknowledge/resolve problems, clear history,
or stop a producer implicitly. Any destructive closure/source-stop action must be
separate and explicit. Do not introduce an event bus, plugin ABI, document registry,
or async transport just to establish this boundary.

### Shared presentation and interaction direction

- **Common shell:** rounded frame, consistent title and focus indication, inset
  padding, and deliberate surrounding backdrop/gap where space allows. Use the
  accepted editor appearance as the visual reference, not severity as the shell
  theme. Content severity styling remains the adapter's concern.
- **Geometry:** derive outer, frame, padded content, title/footer, and text viewport
  from one layout result. Render, scroll, selection, cursor, and copy hit positions
  must agree, including nonzero origins and Unicode display cells. Budget chrome
  inside the allocation; never paint it over another tile or the document.
- **Defaults and fallback:** normal supporting views should not pin text to the
  screen edge. Start with a one-cell rounded border and modest inset/gap defaults;
  record exact horizontal/vertical padding and placement before implementation.
  On small allocations, deterministically reduce padding/decorations or hide a
  companion before making the primary content unusable. Essential mode/pending/
  failure feedback must survive. Restore the requested comfortable presentation on
  expansion; do not preserve the current six-row prototype ceiling by accident.
- **Capabilities, not document impersonation:** share list navigation and a
  read-only text inspection surface where appropriate. Reuse safe text/cell helpers,
  but do not give every report a file path, dirty bit, edit history, or save/reload
  commands. Grid/chart content need not masquerade as selectable text.
- **Read-only is not inert:** text-capable minor views should provide movement,
  characterwise/linewise Visual selection, and yank without edits. Distinguish
  selected list item, text cursor, and text selection; opening details may switch
  from list navigation to the common read-only text surface.
- **Copy/paste:** copy canonical content text, not border/padding, `>` selection
  markers, clipping markers, or decorative status. Reuse the application's existing
  clipboard route where possible, with explicit supported destinations. Paste only
  reaches content with an advertised input capability; read-only views reject it
  atomically. Starting-owner and pending-key cancellation rules remain shared.
- **Updates:** select/reconcile list items by opaque stable keys using adapter
  policy. Define what happens to text cursor/selection when a presentation snapshot
  changes; a yank must not silently copy different source data than the user selected.
  Copying, selecting, or moving never acknowledges or resolves a problem.

## Next tile-system assignments — Phases 7A–7C

These are new assignments after the implemented phase 7, not retroactive changes
to its completion record. Implement in order; keep this application buildable and
usable at each checkpoint. Use the existing software/human acceptance contract.
Phases 7A–7B are software-complete and human-accepted (records below); 7C is
software-complete / human-feedback-pending. They should precede new
history/external view UI rather than growing another problems-specific branch.

### Phase 7A — Extract generic tile host and routing; migrate problems

**Depends on:** phases 6–7's working examples; no LSP, history, or external source.

**Scope:** Extract the smallest service-agnostic view identity, capability, focus/
capture, and input-routing boundary needed by the current document/status/problems
workspace. Keep allocation simple; a general split-tree editor or multiple buffers
is not required. Keep one editor/controller and its established command semantics.

**Work items:**

- Record concrete host/adapter APIs and ownership. Generic IDs/selection keys must
  not be `Problem.Identity`; major/minor is policy metadata, not a data payload.
- Centralize focus transitions, workspace-navigation precedence, pending cancellation,
  start-owner paste, cursor ownership, and hide/zen/resize reconciliation. Preserve
  the existing lazy document-scroll resize behavior and undo/dirty state.
- Move problems-specific filters, item reconciliation, details, acknowledgement,
  and jump dispatch behind a problems adapter. Shared dispatch may carry opaque
  adapter actions, but must not interpret their domain meaning.
- Demonstrate the boundary with a non-problem static list/report fixture in tests
  and an explicit manual test path. No real external producer is necessary; do not
  extend `--demo-problems` into the universal tile content protocol.

**Acceptance:** Document, status, problems, and unrelated fixture coexist using
shared routing. Tests verify focus/prefix/paste/cursor ownership, updates while
hidden/focused, return on hide/zen/resize, and editor undo/dirty preservation. Shared
host/interaction modules have no error-system dependency. Showing/closing either
view cannot mutate the other's authoritative data. Human review checks that the
existing controls still feel predictable; record any deliberate binding changes.

#### Phase 7A implementation choices (2026-10-05)

**Status (2026-10-05): software-complete and human-accepted (see feedback below).**

- **Shared library.** A new `tile/` library, `ches_tile`, depends only on `core` and
  `ches_input`; dune therefore rejects any use of `ches_error`, `ches_app`, or the
  controller from shared code. It holds:
  - `View_id`: opaque, string-backed stable view identity. Applications name views;
    the library enumerates none.
  - `Spec`: per-view role (`Major`/`Minor`, metadata only), title, and capabilities
    (`focusable`, `accepts_paste`, `owns_cursor`). Role implies no capability.
  - `Navigation`: shared list motions (`j/k`, `gg/G`, `Ctrl-d/u`), key-based list
    selection (`'key Selection.t`, keys supplied by the adapter), and a clamped
    row offset for scrollable content. The default reconciliation keeps the
    selected key; when that key disappears it picks the item now at the previous
    index, or the last item. This is the policy phase 7 already used.
  - `Host`: the primary (document) view ID, the focused view, the pending capture
    prefix, the capture notice, and the paste being collected with its starting
    owner. It routes one key and returns a decision: a workspace view command, an
    opaque content action, return to the primary view, a notice, or nothing to do.
    The leader (Space) always begins a workspace sequence looked up in the
    configured keymap. Editor commands and document scrolling are rejected
    during capture. Escape cancels a pending prefix, then takes the content's
    escape action if it has one (closing details, say), then returns. Tab returns;
    Ctrl-c gives a notice. Focus is effective only while the view is available
    (allocated); `reconcile` returns to the primary view otherwise. Paste goes to
    its starting owner and is rejected unless that view accepts paste.
- **Workspace.** `Pane_id` becomes `Document | Status | Minor of View_id.t`.
  `allocate ?minors` takes the requested visible minor views in a stable order and
  shares the existing three-to-six-row bottom band between them side by side,
  splitting its width equally. Each needs at least 16 columns; views that don't
  fit are left out (compact) in reverse order, and their requests are kept.
  `Workspace.t.problems` becomes `minors : Pane.t list` with a `minor` lookup.
  `Pane.focusable` is removed: focusability belongs to the host's `Spec`.
- **Adapters (in `ches_screen`).** `Problems_tile` holds the problems view state
  (filter, identity selection, details, detail scroll). It interprets content keys
  into problems actions (`e` inspect/details, `a` acknowledge, Enter jump) and
  performs them through the controller. Only the problems adapter knows
  `Ches_error`. `Report_tile` is the static, error-free fixture: labelled items with
  list selection and wrapped details (`e`/Enter toggles, `j/k` scrolls details).
  It uses the same host and shared navigation, never posts feedback, and has no
  file, save, or reload identity.
- **Assembly.** `Ui_state` keeps one `Host.t` plus the adapter states. It
  dispatches host decisions by focused view ID, posts capture notices as
  `Notify` feedback under the view's ID, and reconciles focus/selection after
  each input and resize. Existing problems queries stay as accessors.
- **Bindings and manual path.** All existing problems bindings are unchanged.
  New: `Space v d` shows/hides the demo report and `Space v D` shows/focuses it or
  returns to the document. Both only work when Ches is launched with
  `--demo-report`; otherwise they give a notice. Generic capture notices drop the
  word "problems": `Cancelled prefix`, `Unbound workspace key`, and
  `<Title>: read-only; paste ignored`.

#### Phase 7A implementation and verification (2026-10-05)

- Added `ches_tile` as recorded above. `Problem_navigation` is gone; problems
  selection is `Identity.t Navigation.Selection.t`, with the same neighbor policy.
  `Ui_state.problem_notice`/`problem_pending` became `capture_notice`/
  `capture_pending` (the host's, shown only in the focused view's footer). Existing
  problems behavior, bindings, and footer/header text are unchanged apart from the
  generic notices recorded above. `Workspace.Pane.focusable` was removed.
- `Problems_tile` returns posted or shown-only notices, matching phase 7: rejected
  jumps post feedback, acknowledgement only shows its notice. Leaving a view closes
  its details, as returning did before. Moving directly between minor views
  (`Space v o` / `Space v D`) closes the details of the view being left.
- `Report_tile` and `ches --demo-report` provide the error-free consumer. The demo
  items are static, labelled, and session-local; the last has long details.
- Tests: four pure `ches_tile` expect tests (capture precedence and configured
  workspace bindings, focus availability/reconciliation/cursor ownership,
  start-owner paste, key-based selection and offsets), with a test library that
  also cannot see `ches_error`. Four integration tests in
  `screen/test/test_tile_host.ml`: document/status/problems/report coexistence and
  layout, independence of each view's state and of active problems under
  show/hide/focus/feedback updates, paste/cursor/zen/compact ownership, and
  5,400 allocation/position combinations of two minor views. All earlier phase 6/7
  tests pass unmodified apart from the renames.
- Verified `opam exec --switch=5.2.0+ox -- dune build` and `dune runtest` (all
  pass), and `scripts/smoke.sh` (651 checks pass). It has a new section that drives
  the report through show, focus, details scroll, focus switching with problems,
  paste rejection, return, unchanged saved bytes, and an ordinary launch where the
  bindings are inert.
- **Known presentation gaps (phase 7B):** side-by-side minor views have no gap or
  frame, so adjacent headers can read as one line, and 40-column headers clip.
  The bottom band still uses the phase 6 three-to-six-row prototype height.
- **Software-complete / human-feedback-pending.** Manual check:
  1. `dune exec ches -- --demo-problems --demo-report PATH` on a multiline file.
  2. `Space v o`, `j`, `e`, Escape, `Enter` (jump), then `Space v D`: confirm the
     problems controls feel unchanged.
  3. In the report: `G`, `e`, `j/k` and `Ctrl-d/u` through the long details,
     Escape, Tab.
  4. Move between the views with `Space v o` / `Space v D`. Try a paste and an
     editor key such as `Space w` inside the report. Resize narrow (below 32
     columns, which drops the report) and use zen with it focused.
  5. Edit and undo afterwards.
  Assess whether focus ownership is predictable, whether the `Space v d`/`D`
  bindings are acceptable, and whether side-by-side placement is tolerable until
  phase 7B.

#### Phase 7A human feedback (2026-10-05)

- The owner confirmed the demo report works. Binding choices (`Space v d`/`D`) are
  accepted as provisional: a command palette is being developed on another branch
  and may replace or reorganize view bindings. Phase 7A is human-accepted. The
  side-by-side spacing gap remains phase 7B work.

### Phase 7B — Shared rounded shell, padding, and comfortable allocation

**Depends on:** phase 7A.

**Scope:** Give supporting tiles the same visual family as the editor through a
common shell/layout contract. Factor reusable document decoration where useful,
but preserve the accepted document placement and do not rewrite core editing.

**Work items:**

- Record shared rounded-frame, padding, title/footer, focus, gap, preferred-size,
  and compact-degradation defaults. Explicitly reconsider bottom problems height
  so there is useful text space after chrome; tune for the owner's laptop/monitors.
- Render problems list/details and the unrelated fixture through the shared shell.
  Apply it to dedicated status where appropriate; compact status/title remains a
  presentation mode and must retain essential priorities, not a forced framed tile.
- Keep shell insets, clipped rows, content origin, scroll range, and terminal cursor
  derived from the same geometry. Preserve semantic content styles without letting
  the problems adapter implement its own frame/padding.

**Acceptance:** Geometry/rendering tests cover offset allocations, coexistence,
Unicode, frame/padding budgets, tiny/zero sizes, and restoration. Normal-sized minor
content has intentional insets rather than edge-hugging text. Compare the document
against its existing comfort baseline. Human review is required for rounded chrome,
spacing, readability/density, focus clarity, and bottom/side placement; record
remaining issues rather than declaring palette/comfort verified by screenshots.

#### Phase 7B implementation choices (2026-10-05)

**Status (2026-10-06): software-complete and human-accepted (see feedback below).**

- **Shell module.** `screen/tile_shell.ml` (`Tile_shell`) owns the shared shell.
  `Tile_shell.layout policy rect` returns one `Layout.t` (outer, framed, padding,
  title/footer rectangles, content rectangle); `Tile_shell.render layout ~focused
  content` draws it. Adapters return `Tile_shell.Content.t` (a title string, an
  optional footer `Label.t`, and body rows sized to the content rectangle) and no
  longer draw headers, footers, frames, or padding. `Ui_state.minor_layout` is the
  single source of a minor view's layout: `Frame` renders through it, and the
  adapters' selection rows, detail scroll range, and detail wrap width are its
  content height/width. The shell lives in `ches_screen` (it needs `Span`/`Style`)
  and, like `Tile_text`, has no `Ches_error` use; that is by convention, not a dune
  boundary.
- **Frame and labels.** A one-cell rounded frame in the editor's `Border` style
  (on the backdrop since the 2026-10-06 feedback below).
  The title is set into the top border as `╭─ title ───╮`, the editor's filename
  convention; the footer (key hints, a capture notice, or a pending prefix) is set
  into the bottom border the same way. Labels are cut by display cells with `>`.
  Putting both into the borders means framing costs the same two rows the focused
  header/footer already used. Hints use a new muted `Hint` style; notices keep
  `Warning` and pending keys `Pending`, so they read as chips in the border.
- **Padding.** One blank cell inside each side border; no vertical padding (rows are
  scarce, and the border rows already give vertical breathing room). Padding and
  blank rows use the content background (`Status`), so semantic content styles are
  unchanged. The editor keeps its own `left_padding` of 2; this is the knob to
  revisit if minor content feels tight next to it.
- **Focus.** The focused supporting view's frame uses a new `Border_focused` style
  (the Normal accent). Titles keep their `*` marker, which also keeps focus visible in
  monochrome captures. The editor's frame is unchanged in every focus state.
- **Degradation.** `Policy` holds per-consumer defaults. In order: frame with
  padding, frame without padding, then bare. Minor views (`Policy.minor`) need 12 by
  1 content cells to frame, so every minor allocation (at least 16 by 3) is framed
  with padding; bare minor content gets a title row and footer row as before.
  Dedicated status (`Policy.status`) frames only when it leaves at least 8 by 5
  content cells (the full vertical field order) and is bare otherwise, with no
  title/footer rows, so the default six-row stacked status and other shallow or
  narrow cells keep phase 3's unframed rows and essential priorities. Bottom-row
  compact status and the document's border title are untouched.
- **Gaps.** `Workspace.gap = 1`: a backdrop cell between side-by-side panes
  (document/status in a horizontal split and adjacent minor views). Stacked panes
  have no gap; their frames' corner rows already separate them. This revises phase
  2's no-gap policy: a side status now leaves the document one fewer column, and
  side-by-side status needs `16 + 1 + 8` columns before it falls back to compact.
  Minor views fit while `n * 16 + (n - 1)` columns are available.
- **Band height.** Replaces the phase 6 three-to-six-row prototype: the band takes
  `Workspace.preferred_band_height` (10) rows, never more than a third of the
  workspace (but at least `min_band_height`, 3) or what document/status minima need.
  On a laptop or monitor (30+ rows) that is ten rows: eight content rows inside the
  frame. At 24 rows it is eight; at 16 it is five; the band still disappears below
  the document minimum plus three rows.
- **Problems/report content.** Unfocused titles are `Problems (filter): n/total` and
  `Demo report (static): n items`; their hints moved to the footer. Problems
  overflow (`+N more | Space v e: all details`, `Warning`) is now counted in the
  footer instead of costing a content row, revising phase 6. Focused titles and
  footers keep their phase 7/7A text.

#### Phase 7B implementation and verification (2026-10-05)

- Added `Tile_shell`, the `Border_focused` and `Hint` styles (theme: Normal accent and
  Muted on the tile background), `Workspace.gap`/band-height constants, and
  `Ui_state.minor_layout`. Removed `Tile_text.capture`/`capacity`/`footer`; problems
  and report render `Tile_shell.Content.t`. Status renders through the shell.
- Tests: new `screen/test/test_tile_shell.ml` (the degradation ladder for both
  policies at offset origins, including tiny/zero/negative sizes; label placement and
  cell-exact cutting with wide glyphs; focus/notice/pending styles; and a 2 x 40 x 12
  size sweep checking exact rows, sanitized text, every rectangle inside its
  allocation, and that body text starts exactly at the content origin). New
  workspace test for band height across 4–80 rows and gapped minor widths. New
  integration snapshot at 110x30 (framed status, both band views, accent only on the
  focused view) and restoration of the content viewport after shrinking/growing.
  Existing expectations changed only by the gap, the band height (16-row tests now
  have three content rows, so two navigation assertions moved from 4/6 to 3/7), and
  the framed problems/report text. Document-only frame tests are unchanged: the
  editor's placement is the same unless a side status is shown.
- Verified `opam exec --switch=5.2.0+ox -- dune build`, `dune runtest` (all pass),
  and `git diff --check`. `scripts/smoke.sh` passes all 658 checks. Its updates: three
  cursor columns move by the gap with status on the left, and status-cell message cut
  points moved because a framed 28-column status has 24 content columns. New checks
  look for the framed report labels, a notice in the bottom border, framed status and
  problems, and save 120x40 and 200x60 review captures (`tiles-shell-*.ansi`).
- **Software-complete / human-feedback-pending.** Manual check:
  1. `dune exec ches -- --demo-problems --demo-report PATH` on a multiline file, on
     the laptop and on a monitor.
  2. `Space v b`, `Space v d`, `Space v t`: judge the rounded frames, padding, the gap
     between the band views, and the ten-row band against the document.
  3. `Space v o` and `Space v D`: is the accent frame a clear enough focus cue? Try
     `G`, `e`, and scrolling in both; check the footer hints and a paste notice.
  4. Move status with `Space v p h/l/k/j`: side status is framed; stacked status at
     its default six rows stays unframed. Resize narrow and short, use zen, and
     return.
  Assess readability and density (one-cell padding next to the editor's two),
  whether hint text in the bottom border is legible in the muted colour, whether a
  framed side status is preferable to the old unframed one, and whether ten band rows
  are right on each display.

#### Phase 7B human feedback and chrome comparison (2026-10-06)

- The owner reports the shell looks great and works; the framed side status is
  preferred. Open question: the one-cell gap between editor and status shows the
  near-black backdrop between two frames whose cells sit on the editor's gray, and
  the owner asked whether that separation can be given its own look.
- For comparison, a provisional `Space v g` toggled between the existing frames and
  an open look that moves frame cells (`Border`, `Border_focused`, `Title`,
  `Title_special`, `Hint`) onto the backdrop, so rounded corners read as round. A
  first version also drew each gap (`Workspace.t.gaps`, cells belonging to no pane) as
  `▐` in a `Separator` style; the owner found the solid bar redundant next to the
  borders, and a half block cannot centre in its cell (it leaned toward the
  right-hand tile), so it was removed.
- **Decision (2026-10-06):** the owner chose the open look. Frame cells are always on
  the backdrop (a theme change; it applies to the editor's frame too), gaps stay
  plain backdrop, and the tiles' own borders are the separator. The toggle, its
  binding, `Style.Chrome`, and `Frame.t.chrome` were removed; the shipped look has
  no alternate mode. `Workspace.t.gaps` remains as allocation output.
- Tests: gap cells are backdrop, and a theme test pins frame-cell styles to the
  backdrop while tile interiors keep their ground. Smoke passes (658 checks); its
  120x40 check now looks for `╮ ╭─` between the band views.
- Phase 7B is human-accepted. Re-verified 2026-10-06 on `ac34648`: `dune build`,
  `dune runtest`, and `scripts/smoke.sh` (658 checks) pass.

#### Phase 7B open questions (carried forward, 2026-10-06)

The manual check asked about these, and acceptance did not answer them. They are
not blockers for phase 7C; revisit them when the owner next reviews tile comfort.

- **Padding density.** Minor tiles have one cell of side padding; the editor has
  `left_padding` 2. Is one cell tight next to the editor?
- **Hint legibility.** Can the muted `Hint` text in the bottom border be read on
  the open look's backdrop, on both the laptop and the monitors?
- **Band height.** Are ten rows (`Workspace.preferred_band_height`, eight content
  rows) right on each display?
- **Shell boundary.** `Tile_shell` stays error-free only by convention inside
  `ches_screen`. Moving it into a library that dune keeps away from `ches_error`
  (as `ches_tile` is) is still open. Also open: `Ui_state` still wires each minor
  tile by name (visibility flags, `leave`, `synchronize`, `feed_capture`), and
  `View_command` still has commands named per consumer (`Focus_problems`,
  `Focus_demo_report`). Adding a third minor tile, or the per-view state 7C needs,
  means editing each of these.

### Phase 7C — Shared read-only text cursor, selection, and copying

**Depends on:** phases 7A–7B.

**Scope:** Supply reusable read-only text interaction to text-capable minor content,
including problem details and the unrelated report fixture. List-item selection
continues to exist separately. No editable report buffer, multi-buffer registry,
full Vim emulation, or blockwise selection is required for this assignment.

**Work items:**

- Record movement, characterwise/linewise Visual selection, yank, whole-item/details
  copy, copy destination, and Escape precedence. Use familiar editor conventions
  where possible without leaking editor mutations into auxiliary views.
- Define canonical-copy text and text-snapshot/update reconciliation. Keep selection
  and copy correct across wrapping, TABs, wide/combining glyphs, controls, clipping,
  and nonzero viewport origins. Source updates must not silently retarget a selection.
- Give the focused text view an appropriate cursor/selection indication; keep
  exactly one terminal cursor owner. Preserve normal primary-editor behavior.
- Route clipboard output through shared plumbing. Domain actions such as problem
  jump/acknowledgement stay in the adapter and must not be triggered by yank.
  Explicitly reject mutation commands and paste in read-only surfaces.

**Acceptance:** Tests demonstrate navigation beyond the visible rows, selection and
canonical yank, update-during-selection policy, clipboard effects, read-only rejection,
and focus return in both problems and an error-independent consumer. Check a fixture
longer than the viewport: no movement in `Details 1-4/4` is correct because all rows
fit, not evidence of broken scrolling. Human tests select/copy into the editor or an
external destination, inspect long details, switch panes, resize/use zen, and verify
that copied text and keyboard ownership match expectations. Problem lifecycle and
primary-editor undo/dirty state remain unchanged by these interactions.

#### Phase 7C implementation choices (2026-10-06)

**Status (2026-10-06): software-complete / human-feedback-pending.**

- **Shared model.** `tile/text_view.ml` (`Ches_tile.Text_view`) is the read-only text
  surface: a snapshot of canonical text, a cursor, Visual state, a preferred column,
  and a first visible row. It lives in `ches_tile`, which now also depends on
  `ches_core` (for `Cell_layout` and `Register`, neither of which knows errors), so
  dune keeps it away from `ches_error`. It lays text out with `Cell_layout.glyphs` and
  the screen's `Cell_map.width`, so wrapping, the cursor cell, highlighting, and the
  copied bytes agree. Rendering is in `ches_screen`: `Tile_text.text_view` (rows with
  the selection highlighted) and `Tile_text.text_footer`. `Tile_text.wrap` is gone.
- **Where it applies.** Open details are the text surface; lists keep their
  separate key-based item selection. Problems details are the problem's
  `Problems.description`; report details are `title ^ ": " ^ body`. That same string
  is each item's canonical copy text. The status tile is untouched.
- **Positions and rows.** Text splits into logical lines at LF. The cursor is a byte
  offset on a glyph with cells (combining marks belong to the glyph before them) or
  an empty line's start. Lines wrap by display cells to the content width, as
  before; a TAB keeps its width from the unwrapped line. Controls and invalid bytes
  are drawn as their escape forms but copied as their source bytes.
- **Movement (no counts).** `h/l` by glyph within a logical line; `0`, `^`, `$` to
  its start, first non-blank, and last glyph (logical line, not wrapped row, as in
  Vim; in a one-line description `$` is its end); `w/b` to small-word starts across
  lines (the editor's word classes; empty lines stop). `j/k` move by wrapped row with
  a preferred display column (like Vim's `gj/gk`, because details are often one long
  line); `gg/G` first/last row; `Ctrl-d/u` move and scroll by half the viewport. `e`
  is not word-end: it keeps closing details (the 7A binding).
- **Visual and yank.** `v`/`V` start characterwise/linewise Visual, switch kind, or
  end it; `o` swaps ends. Characterwise selection includes each end's glyph and its
  combining marks, and the line break when an end sits on an empty line. Linewise
  selection is whole logical lines (never wrapped rows); its copy always ends with
  LF. `y` (or `Y`) in Visual copies, ends Visual, and puts the cursor at the
  selection start. Outside Visual, `yy`/`Y` copy the cursor's logical line. In a
  list, `yy`/`Y` copy the selected item's whole text, linewise.
- **Copy destination.** Both places an editor yank reaches: the editor's unnamed
  register (new `Editor.set_unnamed_register`, which changes nothing else) and the
  system clipboard through the existing OSC 52 route. `Controller.yank` does both
  without dispatching an editor command, so text, cursor, history, revision, dirty
  state, keymap, and feedback are unchanged. `p` in the editor then pastes it. The
  footer shows `Copied N characters` / `Copied N lines` (shown, not posted).
- **Rejection.** Edit keys (`i I a A o O x X d D c C s S r R p P u U J ~ < > .` and
  `Ctrl-r`; `o` only outside Visual) give `<Title>: read-only; edits unavailable`,
  posted like the paste rejection. The adapter's own keys win first, so `a` still
  acknowledges in problems (list or details) and is rejected in the report. Paste is
  still rejected by the host.
- **Escape precedence.** Host prefix cancellation, then end Visual, then close
  details, then return. Tab still returns directly; leaving a view closes its
  details (and so its selection).
- **Updates.** The problems adapter re-fits open details against current feedback. A
  different selected identity closes details (unchanged). The same identity with a
  different description goes through `Text_view.update`: Visual ends, the cursor stays
  on the same logical line and display column where they exist (clamped otherwise),
  and the view's footer says `Details updated; selection cleared` (or `Details
  updated` without a selection). A later `y` cannot copy the old selection. The
  report's items are static, so only problems exercise this in the application.
- **Cursor ownership.** New `Spec.read_only_text` (problems and report): read-only and
  paste-rejecting like `Spec.read_only`, but it owns the terminal cursor while focused.
  `Ui_state.text_cursor` places it on the text cursor's cell inside the content rect;
  a list has no text cursor, so none is shown (as before). The document draws its
  cursor and smear only when it owns the cursor, so there is still exactly one owner.
  Selection uses the editor's selection style (`Document` with the `Selection`
  overlay) inside the tile.
- **Footers and hints.** Details: `Details a-b/n | hjkl w b v V yy; e/Esc back`, or
  `… | VISUAL: y copy, o swap; Esc cancel` (`VISUAL LINE`). Lists add `yy`:
  `j/k e yy Esc` and `j/k e Enter a yy Esc`. Bindings are provisional, like 7A's,
  pending the command palette.
- **Known limits.** No counts, `e`/`E`/`W`/`B`, search, or blockwise selection in
  details. Layout is recomputed per action (fine for details-sized text). `Ui_state`
  gained one more per-view dispatch (`text_view`), which adds to the 7B open question
  about wiring minor tiles by name.

#### Phase 7C implementation and verification (2026-10-06)

- Added `Ches_tile.Text_view`, `Spec.read_only_text`, `Tile_text.text_view`/
  `text_footer`, `Ui_state.text_cursor`, `Controller.yank`, and
  `Editor.set_unnamed_register`. The problems and report adapters hold a
  `Text_view.t option` instead of a details flag and offset; their `fit` takes the
  content width; `interpret` reads view state; `perform` returns a `Text_view.Effect`
  (copy or notice) that `Ui_state` routes. `Problems.render` takes the open text view;
  `Problems.detail_rows` became `Problems.description`.
- Tests: `tile/test/test_text_view.ml` (5, error-free): movement beyond a three-row
  viewport with the cursor kept visible; rows, cursor, and copy across wide, combining,
  and TAB glyphs; linewise/characterwise copies, empty lines, and Visual switching;
  edit rejection and Escape; the update policy. `screen/test/test_tile_text.ml` (3):
  report details past the viewport with the terminal cursor following; a selection
  across a wrap highlighted exactly and copied as source bytes to the clipboard and
  register, a linewise copy of the whole item, editor revision/dirty unchanged, Escape
  order, and `p`/undo in the editor; problems list/details copies, read-only
  rejection, an update during selection, an unchanged problem lifecycle, and Tab
  return. Two earlier invariants changed on purpose: a focused pane may now draw the
  terminal cursor, but only its text cursor inside its content (the 0–84 x 0–17
  sweep and the 5,400-allocation sweep check this). List footers gained `yy`.
- Verified `opam exec --switch=5.2.0+ox -- dune build`, `dune runtest` (all pass),
  and `git diff --check`. `scripts/smoke.sh` passes all 676 checks. Its new section
  shows the details cursor, selects and copies `REPORT ` in the report, checks the
  copy and read-only notices, closes details (cursor hidden), pastes the copy into
  the editor with `p`, undoes, and saves unchanged bytes. The smoke cannot observe
  the system clipboard (tmux is not asked to forward OSC 52).
- **Software-complete / human-feedback-pending.** Manual check:
  1. `dune exec ches -- --demo-problems --demo-report PATH` on a multiline file.
  2. `Space v d`, `Space v D`, `G`, `e`: the cursor appears in the long last item's
     details. Move with `j/k`, `w/b`, `0/$`, `Ctrl-d/u`, `gg/G`.
  3. Select with `v` and `V` across a wrapped row, press `y`, and check the footer.
     Return (Escape twice, or Tab), `p` in the editor, then `u`. Also paste the system
     clipboard into another application.
  4. `Space v o`: `yy` on a problem; `e`, select part of it, `y`. Try `x`, `p`, `i`
     in details and in the list, and a terminal paste. `a` still acknowledges.
  5. With a selection open, resize narrow and wide, use zen, and switch panes
     (`Space v o` / `Space v D`); confirm keyboard and cursor ownership return
     predictably.
  Assess whether `j/k` by wrapped row and `0/$` by logical line feel right, whether
  copying to both the register and the clipboard is wanted, whether the selection
  colour reads well in a tile, and whether the bindings are acceptable for now.

### Later major-tile specialization

After these shared boundaries work, expand the major-tile contract only for a
concrete consumer. The editor keeps its richer editing/undo/file behavior behind
its content adapter; a future Hardcaml report/workbench could supply structured
reports, charts, drill-down, or source actions while reusing the shell and applicable
read-only interactions. Choose producer/data contracts and required overrides in a
separate assignment. Neither minor tiles nor a read-only major report require the
error system or editor buffer model merely to participate in the workspace.
