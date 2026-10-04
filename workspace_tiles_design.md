# Ches workspace, panes, and status tile

Status: proposed architecture and staged implementation notes. No workspace or
external-view protocol is implemented by this document.

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

- `screen/geometry.ml` computes one document tile, its text/gutter rectangles, and
  a bottom status row. `compute` explicitly reserves one row for status.
- `screen/ui_state.ml` owns one controller, layout preferences, scroll state,
  messages, and animation state.
- `screen/status_field.ml` defines semantic field IDs and priority/fitting metadata.
- `screen/status.ml` produces mode, filename, dirty, message, pending-key, and
  position fields, then renders them for a row or border title.
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
| Save error / file conflict | Prominent and retained until acknowledged or resolved |
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

Execute these phases in order. Keep the existing single document/controller;
multi-view documents, interactive companion panes, and external sources are later
milestones. Each phase should leave the application buildable and usable.

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

Before phase 2, agree on and record the initial status side, requested size,
minimum usable sizes, and compact fallback thresholds. Before phase 3, record the
vertical field ordering and essential-feedback priorities. Before phase 4, agree
on the initial controls and zen/restore behavior. Before phase 5, settle error
retention, acknowledgement, and resolution behavior. An agent should raise these
choices if unresolved rather than silently treating its preferences as requirements.

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

### Phase 2 — Minimal workspace allocation

**Depends on:** phase 1 and recorded initial sizing/fallback decisions.

**Scope:** Introduce stable pane identities and workspace rectangle allocation for
one document and a non-focusable status region. Represent preferred side and
requested dimensions separately from effective geometry. Support deterministic
compact fallback and restoration after resize. Use a minimal layout representation
that can grow toward the split-tree model; a general interactive layout editor is
outside this phase.

**Starting points:** `screen/geometry.ml`, layout preferences in
`screen/ui_state.ml`, and a workspace allocation module if appropriate.

**Acceptance criteria:**

- Allocated rectangles remain in bounds and do not overlap.
- Left/right placement and constrained allocations follow the recorded policy.
- Shrinking and expanding restores requested layout rather than retaining clamped
  dimensions; wide terminals do not independently enable additional panes.
- Document preferred width and comfortable placement remain expressible.
- Focused expect tests cover allocation, compact fallback boundaries, and resize
  restoration without Bonsai or a real terminal.

**Human testing:** Not required for the allocator alone. Actual space balance and
fallback feel will be assessed in phase 4.

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

### Phase 4 — Workspace integration and controls

**Depends on:** phases 1–3 and recorded controls/zen restoration decisions.

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

### Phase 5 — Feedback behavior and milestone acceptance

**Depends on:** phase 4 and recorded error lifecycle decisions. Incorporate any
human feedback already received; keep outstanding human acceptance visible.

**Scope:** Complete essential-feedback behavior across tile, compact, and zen
presentations. Implement retained errors and their acknowledgement/resolution
semantics explicitly where current message handling falls short. Validate the
integrated status-tile milestone against the earlier acceptance criteria.

**Starting points:** message lifecycle in `screen/ui_state.ml`, status field
production/rendering, and workspace integration tests.

**Acceptance criteria:**

- Essential mode, pending-command, and failure feedback survives compact/zen
  transitions according to the recorded policy.
- Errors remain prominent until acknowledged or resolved; routine feedback follows
  its intended lifetime without accidentally clearing retained failures.
- A small suite of expect tests covers message lifecycle and feedback across layout
  transitions, adding regression cases for issues found during integration.
- Relevant software checks and an available terminal smoke check pass; report any
  remaining gaps rather than treating them as verified.

**Human tests — required:**

- Trigger pending commands, routine save feedback, and a controlled save failure;
  assess whether each is understandable and appropriately noticeable.
- Repeat in compact and zen layouts; acknowledge or resolve a failure and check
  that its lifetime feels predictable.
- Use the workspace for a short normal editing session and report friction in
  placement, resizing, controls, or distraction.

End with the explicit software-complete/human-feedback-pending handoff. The
status-tile milestone is human-accepted only after the owner has supplied feedback
and any resulting acceptance blockers have been addressed.

## Later milestones

These are separate from the status-tile assignments. Expand each into a concrete
agent assignment with interfaces, policy decisions, and focused tests before work
starts; apply the same software/human acceptance distinction.

1. **Interactive panes:** Add focus and routing when the next interactive consumer
   arrives. Define workspace navigation precedence, escape from input capture,
   pending-key cancellation, atomic paste routing, and cursor ownership. Human
   testing is required for navigation and interaction feel.
2. **Read-only external snapshot prototype:** Use a synthetic producer and bounded
   latest-snapshot updates. Exercise bursts, producer exit, freshness, resize, and
   reconnect behavior, and measure typing latency. Human testing is required for
   readability, stale-state feedback, and perceived editing responsiveness.
3. **Concrete external integrations:** Add remote transport or richer frame
   protocols only against a concrete producer. Specify lifecycle and recovery
   semantics before implementation. Require human testing for new visible or
   interactive behavior; internal-only transport/encoding changes can be verified
   through software checks.

## Decisions still open

- Initial status size and preferred side; compact fallback thresholds.
- Exact split sizing representation and which layout commands ship first.
- Whether status follows the focused pane or also retains a pinned document summary.
- First external producer and whether its output is semantic data or cell frames.
- Refresh/freshness requirements and acceptable dropped-snapshot behavior for it.
- Which workspace/session/layout settings should persist across launches.
