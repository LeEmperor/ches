# Slang instance context and cross-language references

## User-facing scope

1. **Select active instance**: query Slang's supported extensions for the module
   containing the cursor, offer a searchable hierarchy-path picker, and activate
   the selected elaboration context without editing or navigating the document.
   Show known context visibly; context changes invalidate hover and other
   context-dependent results. Unsupported servers report a clear notice.
2. **Go to instantiation**: navigate to the selected instance's use site via the
   existing safe destination/history machinery. Top-level/no-location cases report
   a notice. No arbitrary server command execution is exposed.
3. **Find references** (`gr` and palette): standard textDocument/references with
   includeDeclaration=true, capability checked, results in a searchable list even
   for a single location. Acceptance uses existing validation/jump history.

Instance controls are palette commands initially, without speculative keybindings.
Reference result lists use a references-specific title/count and the existing
destination UI. Slang module identity comes from server-provided symbols/context,
not an editor-side SystemVerilog parser. Installed command/version differences
must be checked and unsupported commands never sent blindly.

## Boundaries

- Source/error worker: extend language-query transport for references and typed
  instance workflows; inspect cloned server/plugin for exact commands, arguments
  and responses; cancellation/limits/synchronization and context notifications.
- Screen worker: request lifecycle, instance picker integration/status, commands,
  reference result behavior and stale invalidation/history.
- Pure-view/probe worker: instance picker, references title support, and realistic
  live-server scratch probes after source contract is available.

Every request/result retains source/session/document ownership. Instance mutation
can affect multiple files: invalidate server-context-dependent outstanding results
on selection and notifications, including a late mutation acknowledgement after
the UI origin has changed. Never leave old widths visible as a new context's data.
Instance switches do not change text undo history; reference/instantiation jumps
do enter navigation history. No user configuration changes or Git mutations.

## Verification

Scripted Slang command profiles and normal references providers; multi-module file
selection, parameterized narrow/wide instances, null/unsupported/top-level cases,
response races/restart/edits, URI/encoding positions, references dirty targets and
history. Live installed-server probes where possible without building dependencies.
Three participants max, six jobs each, aggregate cap18.

## Status

Implemented and validated. Select active instance and Go to instantiation are
palette commands; Find references additionally uses Normal-mode `gr`. References
always open a titled/count-bearing picker for nonempty results. All jumps reuse
destination validation and navigation history. Context labels appear only after
confirmed activation and while the originating module bounds remain valid.

Instance discovery uses enclosing server module symbols and advertised extension
commands. `module_range` carries the exact negotiated encoding; conversion never
tries alternative encodings. Activation prefers setActiveInstance; its advertised
activateInstance fallback sends integer interactionSource=1, required by the
installed binary. Connection-wide invalidation and retained late-ack observers
prevent a cancelled mutation from leaving stale widths/completions visible.

Final `dune build -j 12 @all`, `dune runtest -j 12`, and `git diff --check` passed,
following source/screen review and exact-encoding suites. No personal configuration
was changed and no staging, commits, or pushes were performed.

Live installed-server scratch probes confirmed references in both servers and
active selection/instantiation locations in Slang after selecting a scratch build
file. Slang version0.3.1+a7a2d08 confirmed narrow/wide context switches but its fresh
hover replies still included both width variants; this is server output, not client
cache merging. An unconfigured standalone file had no instance list. See
`screen/INSTANCE_PICKER.md` and `source/INSTANCES.md` for exact protocol evidence.

## End-to-end review (2026-11-03)

Fixed during review:

- Screen invalidation now uses the authoritative server/resource inventory, so
  a context notification, refresh-derived event, or lifecycle change from another
  pool does not close this pool's pending/visible navigation or completion work.
  Inventory removal/status changes invalidate only the affected source and reset
  only its session-local context revision.
- Activation retains its acknowledgement continuation through the initial
  unknown-context invalidation and matching/partial notifications. These events
  never publish a selected context; the current successful acknowledgement is
  still required. A conflicting confirmed context cancels the continuation.
- Module discovery excludes nested Slang instantiation symbols (which can also
  have kind `Module`) and foreign-file subtrees. Enclosing ranges are half-open,
  keeping adjacent module headers and the end of a module unambiguous. Module
  indexes only filter server symbol identities; names alone never invent ranges.

Review validation covers standard references arrays with zero/one/many locations,
single-result picker acceptance, retained dirty Unicode destinations, external
destination changes and history, cross-pool invalidation, and late completion /
deferred-resolve responses. Existing transport regressions exercise cancelled and
timed-out mutation acknowledgements and shared-connection document invalidation.
The source and screen suites pass with `dune runtest -j6 screen/test source/test`.
Live-server evidence remains recorded in `screen/INSTANCE_PICKER.md`; this review
did not repeat those probes. Exact module-range encoding and its UI conversion
were subsequently completed and tested for UTF-8, UTF-16 and UTF-32.
