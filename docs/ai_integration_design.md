# Ches AI integration: context and proposed direction

Status: design notes, not an implemented feature or a settled protocol choice.

## Goal

Keep code and an AI companion together inside Ches, replacing the need to arrange
separate applications with i3 or tmux. Preserve the comfortable, low-distraction
editing experience and make returning to a zen document view easy.

The owner enjoys inspecting code alongside an AI and does substantial AI-assisted
editing. The immediate need is a useful companion workflow, rather than building
a new agent from scratch.

The workspace and pane foundation is described separately in
[`workspace_tiles_design.md`](workspace_tiles_design.md). This note concerns AI
behavior and its requirements on that foundation.

## What integration means

Integration can grow in independent stages:

1. **Co-location:** an AI interface next to the document, with reliable focus and
   resizing.
2. **Context exchange:** send a selection, current file, diagnostics, test output,
   or a diff to a conversation; open referenced files at the relevant location.
3. **Editing coordination:** handle agent-written files, inspect proposed changes,
   preserve local work, and provide coherent undo behavior.
4. **Native presentation:** render conversations, tool activity, and proposals as
   Ches views backed by a structured agent connection.

The first three address the motivating workflow. Native presentation is optional.

## Connection choices

### Host an existing AI CLI

Advantages:

- Retain the agent's familiar interface and existing functionality.
- Reuse a general terminal pane for shells and other interactive tools.

Costs:

- A PTY connects to the process but does not render its interface. An interactive
  CLI also needs terminal emulation: escape-sequence interpretation, a cell grid,
  cursor state, alternate screens, resize handling, and input encoding.
- Raw stdout rendered as text is sufficient for some logs, not a full-screen CLI.
- Arbitrary CLI output does not reliably expose structured agent state, token
  usage, pending proposals, or context attachments. Display only information the
  integration can actually obtain.
- Context exchange requires a supported interface or explicit user-mediated
  transfer; automating keystrokes into a CLI is a brittle substitute.

Investigate available terminal-emulation libraries before committing to this
route. Terminal support is a substantive feature, not just a split-screen widget.

### Connect to an agent through a structured interface

Ches owns conversation presentation and consumes agent events through a supported
protocol or API. ACP (Agent Client Protocol) is a candidate where supported by the
chosen agent; compatibility and capabilities need verification before selection.

Advantages:

- Structured activity, context attachments, references, and edit proposals.
- Native focus, scrolling, review, and visual styling.

Costs:

- Ches must implement conversation input, streaming output, tool-event display,
  session handling, cancellation, and protocol compatibility.
- Features vary by agent; use capability discovery or explicit adapter capabilities.

Calling a model API directly is a different scope: it also makes Ches responsible
for the agent loop, tools, execution, and conversation management. It is not the
recommended starting point for this workflow.

## Required interaction behavior

### Focus and keyboard ownership

- Make the focused pane unmistakable.
- Provide a reliable workspace escape/focus shortcut even when a CLI owns input.
- Define which keys are workspace commands and which reach the AI interface.
  In particular, do not assume Escape belongs to Ches inside a terminal pane.
- Support zoom/restore and a reversible zen layout.
- Background output must not steal focus or force a reader to the latest message.

### Context and unsaved text

Initial useful actions:

- Ask about the current selection.
- Attach the current document.
- Attach a diff or test result.
- Follow a source reference from a response.

Distinguish a disk-file reference from a snapshot of an unsaved buffer. An agent
reading the filesystem otherwise sees different text from the user. Context
attachments should identify their source and document revision when applicable.
Saving first must be an explicit workflow choice, not a hidden side effect.

Show which context is attached, and allow removal before sending. Treat attached
source text as context, rather than as workspace instructions.

### Changes and review

Support these as distinct workflows:

**Agent writes files on disk:**

- Detect external changes.
- Reload clean buffers while preserving cursor/scroll where practical.
- For dirty buffers, show the conflict and provide comparison/reconciliation;
  never silently replace local edits.

**Agent proposes edits for Ches to apply:**

- Associate proposals with a base revision or equivalent content identity.
- Detect stale proposals when the document has changed.
- Provide a diff and explicit apply/reject actions.
- Apply accepted edits through the normal editing transaction machinery, with
  meaningful undo grouping. Multi-file application and undo semantics need their
  own explicit design; a single-buffer undo stack is not a workspace transaction.

Diff/review and external-change handling are likely more valuable early on than
elaborate chat presentation.

### Session lifetime and asynchronous work

- Session identity is independent of pane identity. Hiding a pane need not stop
  the agent, and reopening it should reconnect to the existing session.
- Distinguish hide, disconnect, cancel current request, and terminate session.
- Process/network work must not block editor input or rendering.
- Bound queued output and retained history; stream bursts should not monopolize
  the UI event loop.
- Surface disconnects, failures, and requests awaiting user input.

## AI-related status

When supported by the adapter, expose semantic status to the workspace:

- Session identity and working project/directory.
- Idle, working, waiting for input, disconnected, or failed.
- Brief current activity, such as running tests.
- Changes awaiting review.
- Optional model/context/cost details when actually available.

The AI pane can carry a compact activity marker in its border. The workspace status
tile can summarize it. Do not infer reliable lifecycle state from arbitrary
terminal prose or require token metrics for basic integration.

## Proposed implementation sequence

1. Establish workspace pane allocation, focus routing, hide/restore, and zoom using
   the status-tile milestone in the companion design.
2. Choose the first AI backend based on the owner's preferred actual agent and
   supported interfaces. Spike either terminal emulation or structured connection.
3. Deliver code and AI side by side with responsive typing and predictable input.
4. Add external-file-change handling and explicit selection/document context sharing.
5. Add diff review and revision-aware application where the backend supports it.
6. Expand structured activity or native conversation features as useful.

## Decisions still open

- Which AI CLI/agent is the first integration target?
- Embedded terminal or native structured interface for that target?
- Which workspace shortcut reliably escapes terminal input capture?
- What context is sent by each command, especially for unsaved documents?
- Does the initial backend write files directly, return proposals, or support both?
- What session state should persist across Ches restarts?

## Success criteria

The owner can edit code, consult an AI alongside it, switch focus without
ambiguity, inspect resulting changes, and return to the previous zen layout.
Streaming output does not degrade typing responsiveness, and agent changes do not
silently overwrite unsaved work.
