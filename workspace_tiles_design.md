# Ches workspace, panes, and status tile

Status: phases 1–5 (geometry, allocation, vertical status rendering, runtime
workspace integration/controls, and shared feedback lifecycle) implemented and
software-verified. Phase 5 is **software-complete / human-feedback-pending**.
Human review of status presentation and workspace interaction from phases 3–4
also remains pending. Problems/history views, diagnostic sources, and the
external-view protocol remain unimplemented.

## Goal and scope

Extend the current single-document layout into a small composable workspace while
preserving Ches's comfortable text placement and zen editing experience.

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
  two-leaf split, with compact fallback. `Ui_state` derives effective workspace
  geometry from saved requests and zen state; `Frame` composes document/status cells.
- `screen/ui_state.ml` owns one controller, layout preferences, scroll state,
  messages, and animation state.
- `screen/status_field.ml` defines semantic field IDs and priority/fitting metadata.
- `screen/status.ml` produces mode, filename, dirty, message, pending-key, and
  position fields, then renders them for a row, border title, or allocated vertical
  status cell.
- `ui/editor_view.ml` renders screen frames through Bonsai and adapts UI events.

These boundaries are useful. Extend them with workspace composition rather than
putting layout or external-process concerns into core editing commands.

## Vocabulary and ownership

Use these conceptual distinctions; final OCaml module/type names should follow the
existing implementation:

| Concept | Responsibility |
| --- | --- |
| Document/buffer | Text, file identity, revisions, dirty state, edit history |
| Document view | A view of a document: cursor, selection, scroll, display preferences |
| Pane/tile | Allocated rectangle, content identity, visibility, focus behavior |
| Session/source | Terminal process, conversation, or external data source independent of visibility |
| Workspace | Layout, focused pane, document/session registries, workspace commands |

A status display is pane content, not an editable text buffer. The same is true of
a dashboard. Avoid forcing all pane contents through editor commands.

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
Existing document geometry currently assumes terminal-wide coordinates and a
top-origin tile; account explicitly for pane origins when generalizing it.

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
and diagnostic sources according to their stated dependencies. Multi-view documents
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

**Status (2026-10-04): software-complete / human-feedback-pending.**

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

## Follow-on phases — Problems, history, and external sources

These are separate implementation assignments, not additional acceptance gates for
phase 5. Follow the dependencies below; record concrete bindings and interface
choices at the start of each assignment. Apply the same software/human acceptance
contract. Phase 9 can proceed after phases 5–6 independently of phases 7–8;
external cell-frame work remains a separate track from semantic diagnostics.

### Phase 6 — Read-only problems tile

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

### Phase 7 — Interactive panes and problem navigation

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

### Phase 8 — Bounded notification history

**Depends on:** phase 5 and phase 7 for an interactive history view.

**Scope:** Make previous action feedback inspectable without mixing it into the
current problems list. Share the existing details/list interaction where practical.

**Work items:** Record bounded chronological notification/lifecycle history with
source and resource context. Specify the capacity, eviction policy, repeated-event
coalescing, and whether ordinary success/layout notices are included. Clearing
history must not resolve active problems; resolving a problem must not erase its
historical occurrence. Keep history in memory initially; cross-launch persistence
and full diagnostic-snapshot logging are out of scope.

**Acceptance:** Tests cover bounds, ordering, repeated failures, acknowledgement,
resolution, and independence from active state. Human tests cover finding an earlier
failure after its notification disappears and understanding past versus current
problems. History must not grow with every render or animation tick.

### Phase 9 — Diagnostic collections and asynchronous source lifecycle

**Depends on:** phase 5; use phase 6's view for integration acceptance.

**Scope:** Extend active problems with source-owned diagnostic collections, using a
synthetic asynchronous producer before implementing a language-server client. This
is semantic feedback data, separate from the external cell-frame protocol below.

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

**Acceptance:** Controlled integration fixtures cover initial diagnostics, editing
and recovery, location conversion including Unicode, source restart, and stale
results. Human tests use a real project, fix an error, follow a location, and repeat
with problems hidden and in zen. Record server/version and any protocol limitations.

## Other later milestones — Externally computed views

The original external-view track remains independent of the feedback phases above.
Expand each into a concrete assignment before implementation; diagnostics do not
require terminal/cell-frame transport.

1. **Read-only external snapshot prototype:** Use a synthetic producer and bounded
   latest-snapshot updates. Exercise bursts, producer exit, freshness, resize, and
   reconnect behavior, and measure typing latency. Human testing is required for
   readability, stale-state feedback, and perceived editing responsiveness.
2. **Concrete external integrations:** Add remote transport or richer frame
   protocols only against a concrete producer. Specify lifecycle and recovery
   semantics before implementation. Reuse phase 7's routing if interactive content
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

- Problems-tile placement/controls, history retention capacity, and the first
  language/server configuration for their respective follow-on phases.
- Human feedback on the integrated status presentation and workspace controls.
- Whether status follows the focused pane or also retains a pinned document summary.
- First external producer and whether its output is semantic data or cell frames.
- Refresh/freshness requirements and acceptable dropped-snapshot behavior for it.
- Which workspace/session/layout settings should persist across launches.
