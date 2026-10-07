# Backlog: externally computed views

Deferred by the owner on 2026-10-06 to close out the workspace-tiles feature set after
phase 10. Moved verbatim from [`workspace_tiles_design.md`](../workspace_tiles_design.md). Nothing here is
implemented. The service-agnostic tile foundation it would reuse (phases 7A–7C:
`ches_tile` host, `Tile_shell`, read-only text) is done. Phase 9's `ches_source`
(Async sources, `Event_queue` latest-snapshot coalescing) is a likely starting
point for the transport side.

## Open decisions

- The first external producer, and whether its output is semantic data or cell
  frames.
- Refresh/freshness requirements and acceptable dropped-snapshot behavior for it.

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
