# Ches syntax highlighting — phased implementation plan

**Status (2026-10-04):** phase 0 technical feasibility verified; owner declined
further bundled-asset provenance/license investigation (“don't care”), so that
unresolved audit is no longer an implementation gate. This is not a finding of
license compliance. Phases 1–4 implementation complete (owner acceptance pending);
phases 5–6 have not started. **Paused for phase 4 owner/visual review.** Incremental
optimization requires separate authorization; no phase 5 work has begun.

## Goal and delivery boundaries

Add local, reliable syntax highlighting without changing editing semantics.
Use **Tree-sitter for baseline syntax**, initially for OCaml `.ml` and `.mli`
files. Leave a provider-independent boundary for **optional LSP semantic tokens
later**. Unsupported files continue to render as plain text.

| Phase | Deliverable |
| --- | --- |
| 0 | Verify binding, runtime, grammar, and query feasibility |
| 1 | Composable document styles; preserve existing appearance |
| 2 | Provider-independent highlight ranges and lookup |
| 3 | Tested OCaml Tree-sitter provider, using fresh parses |
| 4 | Live editor integration and revision-based caching |
| 5A | Correct edit descriptions for incremental parsing |
| 5B | Incremental Tree-sitter updates and measurements |
| 6 | Regression, visual acceptance, and documentation |

**Phases 0–4 are the first useful delivery.** Pause for owner review after
phase 4 before starting incremental optimization. Phase 5 is separately gated
by the feasibility and measurement findings; full parsing is an acceptable
first implementation, not a claim that it scales to arbitrary file sizes.

LSP implementation is **not authorized by these phases**. Its future contracts
are recorded below so today's work does not obstruct it.

## Mandatory instructions for implementation agents

- **No mutative Git operations.** The owner manages Git. Do not use `git add`,
  `rm`, `commit`, `push`, `pull`, `fetch`, checkout/switch, branch creation or
  deletion, worktree creation/removal, stash, reset, clean, restore, rebase,
  merge, tag, or any other Git operation that mutates repository, index,
  worktree, or remotes. Read-only `git status`, `git diff`, and `git log` are
  allowed. Ordinary source-file edits for the assigned phase are expected.
- Inspect applicable `AGENTS.md` and read this plan's shared contracts and your
  assigned phase before editing. Existing code/interfaces take precedence over
  illustrative names here. Preserve unrelated owner or agent work.
- Implement **only the assigned phase**. Do not bundle adjacent phases, expand
  language support, or implement LSP because time remains.
- Aim for **one fresh context/session per phase, without compaction**. Read only
  relevant interfaces, implementations, and tests, not the whole repository or
  dependency tree. Split an oversized phase into named checkpoints here.
- Stop at a coherent boundary **before compaction is necessary**, recording a
  durable handoff. If compaction has already happened, **do not resume substantial
  implementation**: inspect enough to establish the actual state, finish only
  minimal safety/checkpoint work, write the handoff, and stop for a fresh session.
  A partially completed phase is preferable to uncertain completion.
- Do not install packages, modify the active opam switch, or download/build new
  external dependencies without owner approval. Record required commands and
  blockers instead. Approved source vendoring is subject to license review.
- Keep every completed phase buildable and usable. Run its checks and distinguish
  passes, failures, and checks not run. Do not silently bless changed snapshots.
- No commits or pushes at phase completion. Update the status/handoff in this file.

Suggested assignment:

> Implement phase N of `syntax_highlighting_plan.md`, following its shared
> contracts. No mutative Git operations. Stay within one context; if context is
> tight or compaction occurs, checkpoint and hand off to a new session. Run the
> phase checks, update this plan, and stop without starting the next phase.

### Durable handoff format

Append one entry under “Progress and handoffs” with:

1. Phase/checkpoint and status: complete, partial, or blocked; owner acceptance
   is separate from implementation completion.
2. Behavior implemented and exact changed files/interfaces.
3. Decisions, dependency versions, and deviations from the plan.
4. Exact commands run and outcomes, including failures and skipped checks.
5. Remaining work, known risks, and precise next steps for a fresh session.

Do not rely on chat history, a compacted summary, or untracked scratch files as
the only record of important decisions. Never erase previous handoffs.

## Context: what highlighting systems do

- **Lexical highlighting** uses regexes or lexers for keywords, strings, comments,
  and numbers. Traditional Vim syntax and VS Code TextMate grammars are examples.
- **Tree-sitter** parses grammatical structure locally. Highlight queries capture
  tree nodes as categories such as `string`, `comment`, and `function`. It supports
  incomplete code and incremental updates, but generally does not resolve names
  across a project. Grammars, queries, and themes are separate inputs.
- **LSP semantic tokens** come from a language server and can distinguish a type,
  parameter, readonly variable, etc. They supplement baseline syntax, arrive
  asynchronously, and are not required to color comments or strings.

Both providers should ultimately produce document ranges plus categories, never
terminal colors. The theme decides how categories look.

## Existing architecture and starting points

Read `README.md` for current behavior and toolchain, `rendering_design.md` for
safe cell rendering, and `feature_expansion.md` for established agent conventions.
These documents contain historical status/deferred lists; inspect current code
when they disagree. This plan does not reopen unrelated editing milestones.

- `core/text_buffer.mli`: immutable valid UTF-8, LF-only text; zero-based **byte
  offsets at code-point boundaries**. A trailing LF creates a final empty line.
  Current storage is a whole string; do not replace it as highlighting work.
- `core/editor.mli`: pure editor; `revision` increases on text changes, including
  undo/redo. Movement does not increment it. Inspect reload behavior separately.
- `app/controller.ml`: input dispatch and synchronous file effects.
- `screen/ui_state.ml`: Bonsai-free model and transitions, including view state
  and animation. Keep headless testing possible.
- `screen/frame.ml`: obtains text, maps visible lines to glyphs, then applies
  search, selection, and block-insert overlays using document offsets.
- `screen/cell_map.ml` and `core/cell_layout.ml`: byte-to-terminal-cell mapping,
  tabs, wide characters, escaped controls, and clipping; preserve this mapping.
- `screen/span.ml`: styled runs and merging. Combining-mark attachment and
  clipped glyphs need explicit coverage when changing styles.
- `screen/style.ml`: currently a flat variant with combinations such as
  `Text_cursor_line` and `Search_special_match`. Avoid multiplying these by every
  syntax category.
- `ui/theme.ml`: semantic color roles and font attributes; RGB stays here.
- `ui/editor_view.ml`: Bonsai state machine, render/draw, cursor/smear animation.
  Never parse anew on every render, resize, or animation tick.
- `screen/test/`, `ui/test/`, and `test/`: headless and terminal-adapter tests.

Only `ui/` uses Bonsai/Bonsai_term. Core/input/app must not gain terminal or Async
dependencies; screen must remain Bonsai-free. Prefer a separate language/highlight
library for Tree-sitter rather than pulling a parser dependency into editing core.
Choose exact modules and dependency direction in phase 0 without cycles.

### Build and test environment

The tested switch is **`5.2.0+ox` (OxCaml)** with Jane Street `v0.18~preview`
packages. The default switch is not sufficient. Typical commands:

```sh
opam exec --switch=5.2.0+ox -- dune build
opam exec --switch=5.2.0+ox -- dune runtest
opam exec --switch=5.2.0+ox -- dune exec ches -- PATH
scripts/smoke.sh
```

Confirm the environment rather than assuming it. Edit `dune-project` for package
metadata; `ches.opam` is generated by Dune. Preserve the existing `ppx_expect`
source-path workaround described in `README.md`. Smoke tests need tmux and are
not included in `dune runtest`; palette/flicker acceptance still needs a real
terminal. Do not claim checks were run if dependencies prevent them.

## Shared implementation contracts

### Highlight data and freshness

- Normalize provider output to half-open **document byte ranges** `[start, stop)`
  and provider-independent categories. Never confuse byte offsets, code-point
  columns, UTF-16 units, or terminal-cell columns.
- Associate results with document identity, revision, and language/provider
  configuration. Revision alone is not a globally unique document identity.
- Never apply stale results to changed text. Recompute synchronously initially;
  if an implementation later becomes asynchronous, drop obsolete replies and use
  plain text until valid current results exist.
- Define validity, overlap/nesting priority, ordering, and unknown-category
  fallback explicitly. Tree-sitter captures can overlap. Do not depend on an
  undocumented incidental capture order or assume disjoint output.
- Parse the complete document, or use correctly retained parser state. Visible
  lines alone are insufficient: strings/comments can begin above the viewport.
- Cache parse/highlight work by document changes; viewport lookup may be cheap
  per frame. No parse on cursor movement, scrolling, resizing, or animation ticks.
- Empty text, syntax errors, and incomplete constructs are normal editing states.
  Missing grammar/query or provider failure must not stop editing or saving.

### Style composition and compatibility

- Keep document styling components separate: syntax category/default foreground,
  current-line background, special-display treatment, and interaction overlay.
  A text-style record carried by a document variant is one possible design;
  unrelated border/status roles need not become records.
- Preserve existing precedence: block-insert cursor/point overrides selection;
  selection overrides search; current search match differs from ordinary match.
  Overlays may intentionally replace foreground for contrast, matching today's
  behavior. Syntax remains underneath and returns when the overlay is removed.
- Preserve special/control escape readability and partial-wide-character markers;
  decide their foreground precedence explicitly rather than coloring them as code.
- Padding and empty cells receive no syntax category. Preserve current-line fill,
  span widths/merging, combining marks, cursor placement, and safe text display.
- Highlighting is derived presentation state: no changes to text, revision,
  history, dirty state, registers, saved bytes, key bindings, or `%` semantics.

## Phase 0 — Dependency and design feasibility

**Scope:** bounded investigation, a minimal approved build probe if dependencies
are available, and recorded decisions. No renderer refactor or live integration.

1. Verify an actual OCaml Tree-sitter binding against this OxCaml/Dune environment.
   Check parser/tree ownership, C runtime ABI, query APIs, byte/point conventions,
   incremental edit support, error handling, and resource disposal.
2. Identify compatible OCaml implementation/interface grammars and highlight
   queries. Record exact versions/commits, provenance, licenses, and whether
   generated grammar sources or additional build tools are required.
3. Propose reproducible packaging: compiled-in/vendored assets or another explicit
   install layout. No runtime network fetch, external Neovim installation, or
   implicit dependency on development-machine paths.
4. Decide library boundaries, initial categories/capture mapping, overlap policy,
   parser ownership, cache location, and `.ml`/`.mli` detection. Unknown paths and
   extensionless files default to plain text; broad filetype detection is deferred.
5. Record any required owner approvals. If no viable binding is available, stop
   with options; do not quietly implement a new FFI or substitute a regex engine.

**Checks/exit:** where permitted, parse and query a tiny OCaml sample and document
the reproducible build command. Otherwise mark the phase blocked, not verified.
Record enough detail here that phase 3 does not repeat dependency research.

## Phase 1 — Composable styles, without syntax colors

**Prerequisite:** phase 0 architectural decisions (parser installation need not
block a provider-independent style refactor).

Refactor document style composition across `screen/style.*`, `screen/span.*`,
`screen/frame.ml`, and `ui/theme.*`. Update affected callers/tests. Default syntax
category is plain text, so visible behavior should remain unchanged. Preserve the
code-supplied font customization API or explicitly document a necessary change.

**Checks/exit:** build and full test suite; targeted style tests for current-line
fill, search/current match, all selection kinds, block-insert points, escapes,
tabs, clipped wide glyphs, combining marks, and blank padding. Explain snapshot
representation changes; unchanged appearance must not rest on text-only snapshots.

## Phase 2 — Highlight model and frame lookup

**Prerequisite:** phase 1.

Add provider-independent categories, validated ranges, normalization/overlap
resolution, and efficient offset/visible-range lookup in the agreed library.
Add an explicit way for frame rendering to receive a highlight snapshot, with
plain-text defaults for existing callers. Use synthetic highlights in tests;
do not connect a live parser yet. Avoid duplicating search matching logic or
scanning every highlight for every glyph.

**Checks/exit:** synthetic ranges cover multiline text, Unicode byte boundaries,
nested captures, adjacent categories, unknown categories, invalid/empty ranges,
offscreen spans, and stale snapshot rejection at the selected boundary. Verify
overlay precedence and unchanged frame geometry. Build and run tests.

## Phase 3 — OCaml Tree-sitter provider

**Prerequisites:** phase 2 and approved, verified phase 0 dependencies.

Implement the provider and reproducible grammar/query packaging. Freshly parse
the whole document on each provider invocation for now. Map query captures to
normalized categories, resolve overlap according to the recorded policy, and
handle syntax errors and resource cleanup. Keep parser execution out of frame
rendering and editing core. No live UI integration or incremental edits yet.

**Checks/exit:** provider fixtures for `.ml` and `.mli`, keywords, strings/escapes,
numbers, nested multiline comments, recognizable type/function constructs,
Unicode, empty text, incomplete code, and parse-error recovery. Check expected
ranges/categories, not unstable internal tree dumps. Missing/failed provider
returns a documented safe result. Build and full tests pass; record asset licenses.

## Phase 4 — Live highlighting and revision cache

**Prerequisite:** phase 3.

Connect filetype detection and provider execution to the agreed application/model
boundary. Highlight initially loaded text and every changed document; reuse the
snapshot for unchanged text. Plain text is the fallback for unsupported files.
Cover creation, reload, edits, undo/redo, and language changes even if some require
test-only setup in this single-file editor. Parser failure feedback must not spam
each frame or overwrite unrelated editor errors repeatedly.

Add a modest readable palette in `ui/theme.ml`; avoid a theme/config engine.
Keep parser lifetime explicit and rendering observational rather than mutating a
shared Tree-sitter object during a Bonsai render.

**Checks/exit:** integration tests proving parse counts stay unchanged for motion,
scroll, resize, animation, search/selection, and save without text changes; changed
text gets current ranges. Exercise multiline edits above the viewport, paste,
block edits, undo/redo, and `:e!`. Build/full tests; smoke test if available; owner
visual review of `.ml`, `.mli`, and unsupported files. Record full-parse latency
on representative documents and limitations. **Stop for owner review.**

## Phase 5A — Incremental edit descriptions

**Gate:** owner authorizes optimization after phase 4; phase 0 confirms binding
support. Decide whether explicit edit reporting or a conservative snapshot diff
is the smallest correct bridge. Do not redesign history/storage incidentally.

Expose or derive ordered replacements sufficient to update the parser: old/new
byte endpoints and zero-based row/byte-column points. Specify whether each edit
is relative to the prior intermediate snapshot. Multiple block edits, paste,
undo/redo, and reload require coverage; conservative full reset is allowed when
an exact edit sequence is unavailable. A single valid encompassing replacement
is acceptable; it may sacrifice incremental reuse but not correctness.

**Checks/exit:** applying reported replacements reproduces the new text exactly;
point coordinates agree with independent computation. Include non-ASCII text,
newlines, insertion/deletion at EOF, block edits, undo/redo, and reload. Core
purity, revision/history behavior, build, and tests remain intact. No parser
reuse until this boundary is proven.

## Phase 5B — Incremental parsing and performance

**Prerequisite:** phase 5A.

Apply Tree-sitter edits to a correctly owned prior tree and parse the new text
with that tree. Do not share a mutable edited tree between immutable UI/history
snapshots; use verified copying/ownership boundaries. Start with full query
evaluation on the updated tree: changed syntax ranges alone do not establish
that all previous highlight captures remain valid.

**Checks/exit:** differential tests compare incremental normalized highlights
against a fresh parse after edit sequences, including multiline comment/string
changes, malformed code, Unicode, undo/redo, and reload. Measure parsing, query,
normalization, and frame costs separately on reproducible small/medium/large
fixtures. Compare phase 4 numbers; report remaining whole-string/full-query
costs honestly. If incremental querying is warranted, propose a separate phase
instead of hiding it here. Build/full tests; no parse on non-text events.

## Phase 6 — Acceptance and documentation

**Prerequisite:** phase 4 accepted, and phase 5 either completed or explicitly
deferred by the owner.

Complete regression fixtures and update `README.md` with supported languages,
dependency/build requirements, behavior/fallbacks, palette location, and actual
limitations. Update this plan's statuses without rewriting historical handoffs.
Remove only temporary artifacts created by this work, not unfamiliar files.

**Checks/exit:** full build/tests and terminal smoke test where available. Real
terminal checks: readable palette/overlays; typing, paste, scroll, resize, and
smear without observed flicker; multiline edits above viewport; malformed code;
plain-text fallback. Include tabs, controls, wide/combining characters, and tiny
dimensions. Verify saved bytes and undo/dirty behavior are unaffected. Record
unchecked manual behavior and request owner acceptance rather than declaring it.

## Future LSP follow-up — context only, not implementation scope

After baseline acceptance, write a separately authorized plan for process
lifecycle, JSON-RPC/LSP transport, initialization/capabilities, document sync,
and semantic tokens. This is materially larger than adding another color source.

Preserve these future requirements:

- Syntax works without a server; semantic tokens optionally refine foreground
  categories while existing interaction overlays remain highest priority.
- Translate negotiated LSP position encoding (commonly UTF-16) to UTF-8 byte
  offsets. Token types/modifiers come from the server's legend, not fixed numeric
  enum assumptions; decoded tokens must be validated against the source snapshot.
- Requests/replies must be tied to document versions and discarded when obsolete.
  A server's token `resultId` is not an editor revision; full/delta/range support
  and semantic precedence require explicit policies and tests.
- Server startup failure, crashes, delayed replies, and absent capabilities leave
  baseline highlighting usable. Process/async effects stay out of the pure core.

Also deferred: extra languages, injected languages, folding, syntax-aware `%`,
text objects, diagnostics, completion, user query/theme files, config UI, storage
replacement, and grapheme/CRLF redesign. Tree-sitter enables future structural
features but does not authorize changing their semantics in this milestone.

## Progress and handoffs

- **2026-10-04 — Plan created.** Repository architecture inspected; no implementation
  changes, dependency trials, builds, or tests performed. Next assignment: phase 0.

### 2026-10-04 — Phase 0: investigation finished; verification blocked

**Status:** blocked, not complete/verified; owner acceptance is separate. Only
`syntax_highlighting_plan.md` changed. No production code, interfaces, dependency
metadata, renderer behavior, or Git state changed. No dependencies installed,
source archives downloaded, external dependencies built, or source vendored.
Remote source/metadata were read for inspection only. No applicable `AGENTS.md`
was found in the repository or its ancestor directories.

#### Binding candidate and observed API

Preferred first probe: opam **`tree-sitter.0.1.0`**, from
[Mosaic](https://github.com/tmattio/mosaic/tree/0.1.0/tree-sitter)
(GitHub currently redirects to `invariant-hq/mosaic`). Release tag `0.1.0`
resolves to commit **`bbaec9a2b49eccc7be958df1a3fc3f53443787b8`**.
The locally available opam metadata specifies:

- Archive: `https://github.com/tmattio/mosaic/releases/download/0.1.0/mosaic-0.1.0.tbz`.
- SHA-256: `9e4e90d17f9b2af1b07071fe425bc2c519c849c4f1d1ab73cde512be2d874849`.
- OCaml >= 5.1, Dune >= 3.19; no runtime OCaml dependencies beyond the compiler.
  `windtrap` is test-only, `odoc` documentation-only. Remote opam metadata currently
  adds a `< 0.2.0` constraint on `windtrap` that local metadata lacks; do not update
  repositories or install test dependencies incidentally.
- One opam package provides Dune libraries **`tree-sitter`** and
  **`tree-sitter.ocaml`** (and JSON). Do not infer a separate opam package named
  `tree-sitter.ocaml` from the upstream README's library table.
- Binding license: ISC, copyright 2025 Thibaut Mattio.

Inspected pinned files: `tree-sitter/lib/tree_sitter.{ml,mli}`,
`tree_sitter_stubs.c`, `tree_sitter_runtime.c`, `lib/dune`,
`lib/ocaml/{dune,tree_sitter_ocaml.ml,tree_sitter_ocaml.mli}`,
`include/tree_sitter/api.h`, and `config/discover.ml`.
Findings are **source inspection, not evidence of a successful OxCaml build**:

- `Parser.create language`, `Parser.parse_string ?old parser source`,
  `Parser.reset`, `Tree.root_node`, `Node.start_byte/end_byte/start_point/end_point`,
  `Query.create`, and `Query_cursor.exec/next_match/next_capture` cover phase 3.
  Ranges are half-open byte offsets; points are zero-based row/byte-column pairs.
  The C stubs narrow lengths/offsets to `uint32_t`: reject unsupported oversized
  inputs before calling them, rather than silently wrapping.
- Runtime C sources are compiled into the library via `foreign_stubs`, not loaded
  from a system Tree-sitter shared library. Its API header accepts language ABI
  **13–15**; bundled `.ml` and `.mli` generated parsers both declare **ABI 15**.
  The header blob matches Tree-sitter `v0.25.10` (`api.h` blob
  `2bbfe66ffe390dec0cc3aa4dee4ce028b06e8297`). This establishes header identity,
  **not the exact version of all vendored runtime sources**; audit that before
  describing the runtime as unmodified `v0.25.10`.
- Parser/tree/query/query-cursor C custom blocks have deletion finalizers.
  OCaml nodes retain their tree; query cursors retain the tree after `exec`.
  Query cursors do **not** retain the compiled query themselves: the provider must
  keep the query strongly reachable throughout iteration, especially `next_match`.
  Only `Tree_cursor.delete` has public early disposal. Do not invent
  `Parser.delete`, `Tree.delete`, or `Query.delete`. Drop references after use;
  exercise repeated parses and forced GC in the probe. External allocations are
  reported as zero bytes to `caml_alloc_custom_mem`, so timely reclamation/native
  memory pressure must be measured, not assumed.
- `Tree.copy`, mutating `Tree.edit`, and `Parser.parse_string ~old` exist; incremental
  support is plausible but **not verified**. Copy before editing any retained tree.
  The upstream interface's phrase “immutable once created” does not make `edit`
  pure, and its “deep copy” wording should not imply no C subtree sharing.
- Incompatible language, failed parse, and invalid query raise `Failure`; query
  errors include kind and byte offset. Malformed source normally produces a tree
  with error/missing nodes (`Node.has_error/is_error/is_missing`), not a provider
  exception. Keep useful captures on error trees; exceptions yield plain text.
- `Tree_sitter.highlight` extracts captures and skips `_` names/empty ranges.
  **It does not evaluate query predicates.** Raw query cursors do not evaluate
  text predicates either; `Query.predicates_for_pattern` merely exposes them.
  Do not pass a query containing `#eq?`/`#match?` to this helper and assume it works.
  Use predicate-free structural queries initially; predicate evaluation is not an
  incidental prerequisite for this milestone. Normalize overlaps independently
  of upstream capture iteration order.
- `Tree_sitter_ocaml.ocaml ()` and `interface ()` supply the required grammars.
  Avoid its global lazy convenience highlighters: instantiate provider-owned
  parser/query state. Its small embedded query lacks function/escape coverage and
  is not sufficient unchanged for the planned fixtures.

#### Grammar/query provenance and packaging decision

The candidate's generated grammar files are pinned by the Mosaic release commit:
`lib/ocaml/ocaml/parser_ocaml.c` (blob
`67724008e33a04ac9585947e2ec9b7db82741f3c`),
`lib/ocaml/interface/parser_interface.c` (blob
`7866e97b42e8324687981cb685ff42e1ab04e70e`), plus scanner C files and
`lib/ocaml/scanner.h`. The runtime and these generated parsers need a C compiler;
normal package builds do **not** require Node, npm, a Tree-sitter CLI, Rust, or
grammar regeneration. Linux discovery links `-ldl -lpthread`.

Authoritative upstream alternative: **`tree-sitter/tree-sitter-ocaml v0.26.0`**, commit
**`e3c9cf368f68bffd2f81188229aefa7b434eda65`**, MIT (Max Brunsfeld and Pieter
Goetschalckx). `tree-sitter.json` points both implementation and interface grammars
at the same `queries/highlights.scm`; generated sources live under
`grammars/{ocaml,interface}/src/`, with shared `common/scanner.h`.
The query includes structural function/type/module captures, escapes, and OxCaml
constructs, but also text predicates. It cannot be used unchanged with the binding's
highlight helper. The shared scanner header matches the bundled header, but parser
blobs differ; **the exact upstream origin/regeneration of Mosaic's generated parsers
was not established**. Do not assert that they are `v0.26.0` or mix its complete
query with those parsers without compiling/testing against both languages.

Packaging choice for the first probe: the pinned opam package's compiled-in
runtime/grammars, with Ches-owned, predicate-free query strings compiled into
`ches_highlight_ocaml` in phase 3. This avoids runtime file search, network access,
Neovim dependencies, or development-machine paths. Query initialization must be
tested separately for `.ml` and `.mli`. If borrowing upstream query patterns,
record the exact source commit, modifications, and retain its MIT notice.
Prefer this package route over new local FFI work.

**License/provenance gate:** the inspected Mosaic tree has the binding ISC notice
but no separate runtime MIT, grammar MIT, or Unicode notice in its Tree-sitter
subtree. Tree-sitter upstream `v0.25.10` is MIT and ships an additional
`lib/src/unicode/LICENSE`; do not treat all bundled C sources as ISC. Audit the
release archive/installed notices and upstream provenance before distribution or
vendoring; preserve all applicable notices. If the package cannot pass that audit,
ask the owner about an audited vendor/repackaging of this existing binding and
explicitly pinned upstream C assets. Do not silently write a replacement FFI.
The archived Semgrep `ocaml-tree-sitter-core` is not selected: its typed-CST/codegen
scope and separate license review add complexity without establishing a better
highlight-query boundary. No claim is made that it or other bindings are infeasible.

#### Architectural decisions for subsequent phases

- Phase 2: `highlight/` library **`ches_highlight`**, depending only on `core`
  (Jane Street), with `Category`, `Language`, `Snapshot`, and range normalization/
  indexed lookup modules. It takes source strings, identity and revision, not
  terminal coordinates; it does not depend on `ches_core` or a parser library.
- Phase 3: separate `highlight_ocaml/` library **`ches_highlight_ocaml`**, depending
  on `ches_highlight`, `tree-sitter`, and `tree-sitter.ocaml`. It owns parser/query
  handles and exports only normalized OCaml data, never nodes or mutable trees.
- Phase 4: `ches_app.Controller` owns document identity, provider session and cached
  immutable snapshot. Update synchronously after initial creation/load and any
  final text revision change in `handle_input`; motion/save reuse the snapshot.
  `ches_screen` depends on `ches_highlight` for styles/frame lookup, never directly
  on the parser provider; `Ui_state` carries the controller as it already does.
  `ui/` supplies colors. Dependency direction has no cycles and core/input stay
  parser-free; frame generation and Bonsai render remain observational.
- A fresh controller/document gets a new opaque identity (not just a pathname).
  Snapshot key: identity + `Editor.revision` + language/provider/query configuration.
  Successful reload already increments revision even if bytes are identical;
  failed reload does not. Reset provider state on reload/configuration change.
  Independently reject mismatched snapshots at the frame boundary. Parser sessions
  never go into text/history; future incremental trees stay privately owned.
- Detect only case-sensitive `.ml` => implementation and `.mli` => interface on
  the associated path. Missing path, extensionless path, and other suffixes => plain
  text. Do not sniff text, change file associations, or expand language support.
- Initial categories: `Keyword`, `String`, `Escape`, `Number`, `Comment`, `Type`,
  `Constructor`, `Module`, `Function`, `Variable`, `Property`, `Operator`,
  `Punctuation`, `Constant`. No capture/unmatched text means default foreground.
  Map dotted upstream families explicitly: `function.*` => Function,
  `type.*` => Type, `variable.*` => Variable, `punctuation.*` => Punctuation,
  `string.special` => String, `escape` => Escape, `tag` => Property. Unknown and
  `_` captures are ignored rather than masking known highlights.
- Validate bounds/code-point boundaries; discard empty/invalid ranges, deduplicate,
  and resolve with a sweep into sorted disjoint half-open spans. Per covered byte,
  the shortest recognized range wins (nested specificity); equal length uses fixed
  priority: Escape > Comment > String > Keyword > Function > Type > Constructor >
  Module > Property > Constant > Number > Operator > Punctuation > Variable.
  Remaining ties use ascending `(start, stop, category)` for reproducibility,
  never capture order. Merge adjacent identical-category spans. Query patterns
  must not create broad code captures inside comments/strings. Phase 2 tests this
  policy including crossing overlaps; binary-search spans, not per-glyph full scans.
- In phase 1, absent syntax category preserves today's foreground. Special/control
  escapes and clipped-glyph markers retain their special foreground above syntax;
  interaction overlays retain the plan's existing precedence above both. Padding
  has no syntax. Provider failure caches an empty current snapshot, not stale ranges;
  retry only on a changed key/explicit reset and do not replace editor feedback.

#### Checks run, skipped checks, and next approved checkpoint

Environment confirmed: `5.2.0+ox`, `ocamlc -version` => `5.2.0+ox`,
`dune --version` => `3.24.2`. Exact local commands/outcomes:

- `git status --short`: only the pre-existing untracked plan; no other changes.
- `opam switch list --short`; `opam list --switch=5.2.0+ox --installed --short`:
  expected switch exists; no Tree-sitter package installed.
- `opam show tree-sitter --field=all-versions`: `0.1.0`.
- `opam show tree-sitter.0.1.0 --raw`: success; metadata recorded above.
- `opam exec --switch=5.2.0+ox -- ocamlfind query tree-sitter`: exit 2,
  `Package tree-sitter not found` (expected dependency blocker).
- `opam exec --switch=5.2.0+ox -- ocamlc -version` and
  `opam exec --switch=5.2.0+ox -- dune --version`: success, versions above.
- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest`: passed in the initial sequential
  run and final standalone retry. An intervening concurrent invocation failed
  with `Another Dune instance is currently running`; no test failure or snapshot
  promotion. Run build/tests sequentially in subsequent sessions.
- Two metadata attempts using `--field=url.src,...` / `--field=...,url` failed
  (`No printer`); `--raw` succeeded instead. Web search was cancelled; direct
  GitHub source/API reads succeeded. Two guessed scanner paths returned 404 and
  were corrected to `grammars/ocaml/src/scanner.c`. A large-source comparison
  exceeded the HTTP inspection tool's string limit; parser identity is explicitly
  left unverified, not inferred from the matching scanner/header.
- **Not run:** binding build/link, `.ml`/`.mli` parse/query probe, incremental/GC
  stress checks, dependency archive/license audit, terminal smoke/visual checks.
  Existing Ches build/tests do not verify Tree-sitter.

**Required approval:** acquire/build `tree-sitter.0.1.0` and its pinned archive,
preferably in an owner-approved isolated switch/probe workspace. If the owner
approves the active switch explicitly, the candidate install command is:

```sh
opam install --switch=5.2.0+ox tree-sitter.0.1.0
```

Do not run it without approval; review the solver's proposed changes first and
stop if it would replace the OxCaml compiler or existing Jane Street packages.
No test/doc dependency installation is needed for the minimal probe.

Fresh phase-0 verification session: audit the archive, install/build as approved,
then make a standalone Dune executable linking `tree-sitter tree-sitter.ocaml`
and run `opam exec --switch=5.2.0+ox -- dune exec ./probe.exe` from that approved
workspace. This is the **planned command, not an existing or executed probe**.
Use `let f x = "é" (* outer (* inner *) *)\n` and `val f : int -> string\n`:
create each language/parser/query explicitly; query `(comment) @comment`,
`(string) @string`, `(number) @number`, `(value_name) @variable`, and `"let"` or
`"val"` as `@keyword`; assert exact source byte slices and exclusive ends.
Also parse empty/incomplete text, reject an invalid query safely, keep nodes alive
across forced GC, and check copied-tree edit/reparse equivalence on a tiny ASCII
replacement (without implementing phase 5). Confirm native memory reclamation
over repeated fresh parses. Record executable source, exact command/results and
asset notices durably, then mark phase 0 complete only after a successful OxCaml
parse/query check. If acquisition/build/cleanup is not viable, stop with findings
and ask the owner to choose an alternative. Phase 1 can proceed using the
provider-independent design above; phase 3 remains gated.
### 2026-10-04 — Owner-requested dependency declaration

Owner requested declaring the candidate dependency and will install it manually.
Added exact `tree-sitter = 0.1.0` dependency to `dune-project`; regenerated
`ches.opam` with `opam exec --switch=5.2.0+ox -- dune build` (passed). No Dune
library links/provider code added, and no package installed by the agent.
Manual command: `opam install --switch=5.2.0+ox tree-sitter.0.1.0`.
Phase 0 remains blocked on installation, parse/query verification and the asset
audit above; successful existing builds do not validate the new dependency.

### 2026-10-04 — Phase 0 verification checkpoint: parse/query passed

**Status:** verification checkpoint complete; phase 0 partial pending asset
provenance/notice resolution, not owner-accepted. Owner installed
`tree-sitter.0.1.0` in `5.2.0+ox` and requested a usability trial. No installation,
vendoring, FFI implementation, or adjacent phase work performed by this agent.

**Changed files:** added `scripts/syntax_probe/dune` and
`scripts/syntax_probe/probe.ml`; updated this plan. The standalone executable links
the existing Dune libraries `tree-sitter` and `tree-sitter.ocaml` within Ches's
actual project. It is explicitly invoked, not part of `dune runtest` or the editor.
No production interfaces or renderer behavior changed. Dependency declarations
from the preceding checkpoint remain intact; unrelated untracked design documents
were untouched.

**Verified behavior:** both grammars report ABI 15 and successfully compile
Ches-owned predicate-free structural queries. `.ml` and `.mli` fixtures verify
keywords, function captures, type captures, strings, nested comments, numbers and
escapes. Exact `[10,14)` range for `"é"` and row/byte-column EOF checks confirm
UTF-8 byte conventions. Empty input returns no captures; incomplete input produces
a queryable error tree; invalid node names in queries raise `Failure`. A node and
a query cursor retain their trees across forced major collection. A copied-tree
ASCII replacement preserves the original and produces the same tree/captures as
a fresh parse. These are feasibility checks, not the complete phase 3 fixtures
or phase 5 differential tests. No custom FFI is required by this successful probe.

**Commands/outcomes:**

- `git status --short`: existing modified dependency files, untracked plan and
  unrelated design documents; read-only inspection only.
- `opam list --switch=5.2.0+ox --installed tree-sitter`: installed `0.1.0`.
- `opam exec --switch=5.2.0+ox -- ocamlfind query tree-sitter` and the same command
  with `tree-sitter.ocaml`: both resolve inside the expected switch.
- `opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_probe/probe.exe`:
  passed all assertions; repeat this exact command to rerun the probe.
- `opam exec --switch=5.2.0+ox -- dune build`: passed with the linked probe.
- `opam exec --switch=5.2.0+ox -- dune runtest`: passed; no snapshot promotion.

**Resource observation:** 800 fresh parser/query/tree cycles on a 19,500-byte
fixture, in four batches of 200. Linux `/proc/self/status` RSS after forced major
GC/compaction was 13,228 KiB before stress, then 95,696 / 95,712 / 95,716 / 95,724
KiB. RSS approximately plateaued after the first batch, but retained memory is
substantial; this does not prove prompt native disposal or leak freedom. The
probe deliberately forces GC for observation, **not a recommendation to force
GC on editor input**. Fresh parsers in stress are more aggressive than the planned
provider-owned reusable parser. Production memory/latency measurements remain
required in phases 3–4, particularly given zero external-memory accounting in
the binding's custom allocations.

A second probe run, after strengthening the unchanged-original capture assertion,
also passed; RSS was 13,364 / 95,780 / 95,792 / 95,804 / 95,808 KiB.

**Asset audit result:** inspected the locally installed package sources at
`~/.opam/5.2.0+ox/.opam-switch/sources/tree-sitter.0.1.0` and installed documentation
at `~/.opam/5.2.0+ox/doc/tree-sitter`. The Tree-sitter subtree and installed docs
have only the binding ISC license, not separate runtime/grammar MIT or Unicode
notices. No upstream runtime/grammar pin was found in the inspected Markdown,
shell, or JSON sources. Existing opam sources were read only; no external source
download/build was undertaken. These development paths are audit evidence only,
not proposed runtime asset locations.

**Remaining gate/next steps:** technical use in this OxCaml/Dune project is now
demonstrated. Phase 1 can start; keep phase 3 packaging gated until upstream asset
provenance and applicable notices are resolved (upstream correction or an
owner-approved audited packaging route). Do not relabel the entire C bundle ISC,
infer exact upstream versions, or silently vendor/rewrite FFI. Predicate evaluation
is still unsupported by the highlight helper; use the structural-query approach
recorded above. Terminal smoke/visual tests and live provider integration were not
run and are outside this checkpoint.

### 2026-10-04 — Owner audit disposition and phase 1 completion

**Owner disposition:** explicitly declined further provenance/license investigation
(“don't care”) and requested phase 1. Phase 0's technical feasibility is verified;
the audit remains unresolved but is **not an implementation gate**, superseding
the gate in earlier handoffs. This records the owner's prioritization, not license
compliance or permission from upstream licensors. No further audit, dependency
installation, source vendoring, or FFI work performed in phase 1.

**Phase 1 status:** implementation complete; owner acceptance separate. No phase 2
range model, syntax palette, parser provider, caching or live integration started.

**Changed files/interfaces:**

- `screen/style.ml`, `screen/style.mli`: flat document-style variants replaced by
  `Document of Document.t`, with independent `syntax`, `current_line`, `special`,
  and optional `overlay` fields. `Syntax.Plain` is deliberately the only syntax
  value in phase 1; phase 2 will move categories to `ches_highlight`. Five overlay
  variants distinguish ordinary/current search, selection and block-insert
  cursor/copied point. `Style.document` constructs defaults; `Style.with_overlay`
  replaces only the overlay and rejects chrome styles. Chrome variants unchanged.
- `screen/span.ml`, `screen/span.mli`: interaction highlighting updates the
  document overlay instead of replacing the whole style. Span merging compares
  the complete style. Width/clipping/padding/combining behavior unchanged.
- `screen/frame.ml`, `screen/frame.mli`: construct composed current-line and
  special styles; document padding remains plain with current-line fill. Existing
  precedence resolution stays at the frame boundary: insert points > selection >
  search. Frame dumps use `Style.to_string_hum`, retaining compact historical
  appearance labels; structural `sexp_of_t` exposes all record fields.
- `ui/theme.ml`, `ui/theme.mli`: resolve document colors from composed fields.
  Palette RGB values unchanged. Interaction overlays replace both colors for
  contrast; absent overlay uses special/default foreground and current-line/default
  background. All document default fonts remain plain; chrome defaults unchanged.
- `screen/test/test_span.ml` (new): compositional retention/removal, full-style
  merging, current-line blank fill/padding, every overlay on text/TABs/control
  escapes, clipping at both wide-glyph edges, partial escapes/TABs, combining
  attachment/suppression and exact cell widths.
- `screen/test/test_frame.ml`: adapt full-style equality assertions for retained
  current-line data; add characterwise/linewise/blockwise selection-over-search,
  restoration after Escape, and block-insert cursor/copy precedence tests.
- `ui/test/test_theme.ml`: compare actual terminal attributes for all 24 composed
  plain document combinations with the previous foreground/background mapping;
  verify default/custom fonts. Exactly one expectation changes from `(Text ())`
  to the structural `Document` record; manually reviewed, no snapshot promotion.
- `README.md`: document record matching for code-supplied font customization.

**Compatibility decisions:** `Theme.attrs ~font` and `Editor_view.run ~font` keep
their callback signatures. Source callbacks matching removed flat constructors
must instead match `Document` fields; examples are in README/theme interface/tests.
Special foreground sits above the future syntax foreground, below interaction
overlays for complete glyphs. Preserve existing exceptions: partial escape fragments
and clipped-wide markers retain the unoverlaid special style; partial TABs retain
their overlay. Combining marks continue using supplied base-text style (including
when the preceding glyph has an overlay), and only attach after fully visible plain
glyphs. Phase 1 deliberately does not fix or redesign these historical edge cases.
Compact frame snapshots are unchanged, but appearance compatibility is also checked
with terminal attribute equality, not just those labels or text-only output.

**Exact checks/outcomes:**

- `git status --short`, `git diff --check`, `git diff --stat`, targeted `git diff`,
  and `git log -3 --oneline`: read-only inspections. No mutative Git commands run.
  Owner/tooling committed changes during execution; no commits/staging performed
  by this agent and no user changes reverted.
- `opam exec --switch=5.2.0+ox -- dune build`: passed after one initial syntax error
  in a new test's tuple type annotation was corrected.
- `opam exec --switch=5.2.0+ox -- dune runtest`: passed after correcting the compact
  dump's chrome sexp spacing and manually matching the expected new record layout.
  The initial failing run showed only those formatting expectation differences;
  no corrected snapshots were promoted.
- `scripts/smoke.sh`: **failed, exit 1, five checks**. Cursor-row assertions for
  tall scrolling, counted motion, and document motion, plus two wide-line cursor
  assertions sampled with `cursor_flag = 0` and visible smear cells. Other smoke
  checks passed, including controls/wide geometry, block-selection colors,
  block-insert point colors, saved bytes and terminal restoration. Animation timing
  is a plausible cause but was not independently proven against a pre-change
  binary; do not claim smoke passed or conclusively classify it as pre-existing.
  Review captures: `/tmp/ches-smoke-screens.opmcZS`. No animation or smoke-script
  changes made, because they are outside this phase.
- Real-terminal palette/flicker/font review not performed; automated attribute
  tests passed. No change to core/input/app editing semantics or dependencies.

**Next session:** phase 2 only. Replace/alias the phase-1 `Syntax.Plain` placeholder
with the agreed provider-independent categories in `ches_highlight`, add validated
snapshots/normalization/indexed lookup and synthetic frame tests. Do not introduce
live parsing or new palette colors yet. Retain current style data under overlays,
special/clipping behavior, and full-attribute regression tests. Smoke cursor timing
failures remain a recorded follow-up, not a silently accepted successful check.

### 2026-10-04 — Phase 2: highlight model and synthetic frame lookup complete

**Status:** implementation complete; owner acceptance separate. No live parser,
filetype detection, controller cache, syntax palette, incremental work, or LSP
implemented. The pre-existing phase 1 handoff/local plan edits were preserved.
No mutative Git commands, dependency installation, switch changes, or downloads.
No applicable `AGENTS.md` found in the repository or ancestor directories.

**Changed files/interfaces:**

- New `highlight/dune`, `highlight/category.{ml,mli}`,
  `highlight/language.{ml,mli}`, and `highlight/snapshot.{ml,mli}` provide the
  Core-only `ches_highlight` library. Categories include the fourteen agreed roles
  plus `Plain`; recognized capture-name families map explicitly, while unknown
  roots and internal `_` captures return `None`. `Language` describes plain text,
  OCaml implementation, and OCaml interface; path detection remains phase 4.
- `Snapshot.Document_id.create` allocates an opaque identity. `Snapshot.Key.create`
  combines identity, revision, language and a provider/query configuration string.
  `Snapshot.Range` is the raw range record. `Snapshot.create` validates UTF-8 source
  and discards empty, reversed, out-of-bounds, non-code-point-boundary and Plain
  ranges. It deduplicates and sweeps events into immutable sorted disjoint spans,
  merging adjacent equal categories. `ranges`, `category_at`, `intersecting`, and
  `lookup_from` expose safe indexed access without exposing the backing array.
- `screen/dune` adds only `ches_highlight`, not the parser provider.
  `screen/style.{ml,mli}` alias `Style.Syntax` to `Category` and add `with_syntax`.
  Compact dumps retain old plain/overlay/special labels; unmasked syntax uses
  category labels, with a current-line suffix. Structural sexps retain all fields.
- `screen/span.{ml,mli}` add an optional glyph-category callback to `of_glyphs`.
  Syntax is applied before interaction overlays. Complete escapes retain their
  underlying category and special treatment. Clipped escape/wide markers retain
  plain special style; clipped TABs retain syntax/overlay. Combining marks keep
  their per-glyph text category without an interaction overlay, preserving the
  previous attachment rule. Final blank fill never receives the callback.
- `screen/frame.{ml,mli}` add optional `~highlights:(expected_key, snapshot)`.
  Mismatched identity/revision/language/configuration or an expected revision
  different from the actual editor revision produces plain text. Each document
  line initializes a binary lookup, then advances monotonically across glyphs;
  synthetic block-insert extension cells remain Plain. Existing callers are
  unchanged and no provider runs during rendering. Search code is unchanged.
- `ui/theme.ml` accepts every category but intentionally retains the existing
  palette and default fonts. Syntax colors remain a phase 4 deliverable.
- New `highlight/test/dune`, `highlight/test/test_snapshot.ml` test nesting,
  crossing overlaps, priority/ties, duplicate/order independence, adjacent merging,
  UTF-8/multiline validity, unknown capture fallback, empty/invalid source/ranges,
  dense offscreen intersections, forward/repeated/backward lookup, and every key
  component. A fixed-seed 100-document test compares sweep output with an independent
  per-byte shortest-range/category-priority oracle.
- `screen/test/dune`, new `screen/test/test_syntax.ml`, and
  `ui/test/test_theme.ml` cover synthetic Unicode/multiline frames, independent
  stale-revision rejection including undo, identity/language/configuration mismatch,
  search/current search, every selection kind, block-insert points, restoration,
  dense offscreen spans, tabs/controls/combining/clipping, blank insertion padding,
  unchanged text/cursor/smear/row widths, and actual terminal-attribute equality for
  all 360 category/current-line/special/overlay combinations. No existing snapshots
  changed or were promoted.

**Decisions and boundaries:** normalization is O(source bytes + captures log captures),
offset lookup O(log spans), intersections O(log spans + results), and a monotonic
line cursor O(log spans + glyphs + crossed spans). The agreed shortest-original-range
policy and exact fixed category priority are implemented; captures are never ranked
by incidental provider order. `Range` and indexed lookup live inside `Snapshot`
rather than separate modules, keeping invariants behind one interface. Snapshots
do not retain source strings or mutable parser state. The application must supply
an authoritative current expected key, not copy it from an obsolete result; this
ownership contract is explicit in `frame.mli`. Phase 4 must supply controller-owned
identity/configuration. Frame rendering checks the editor's revision independently
and performs no whole-document source scan. Invalid UTF-8 passed directly to
`Snapshot.create` raises `Invalid_argument`; normal editor source is already valid.
There are no new external dependencies or changes to editing semantics.

**Exact checks/outcomes:**

- Read-only `git status --short`, `git diff --check`, `git diff --stat`, and
  `git diff -- syntax_highlighting_plan.md`: inspected existing work and changes;
  whitespace check passed. No staging, commits, or other mutative Git operations.
- `opam exec --switch=5.2.0+ox -- dune build`: passed finally. Initial builds
  exposed a missing record type annotation and new tests requiring comparison
  functions; corrected the annotation, derived range comparison, and used existing
  style/cursor equality rather than changing their APIs for tests.
- `opam exec --switch=5.2.0+ox -- dune runtest`: passed after compilation fixes;
  passed again after adding padding/dump-label tests.
- Final `opam exec --switch=5.2.0+ox -- dune build` and
  `opam exec --switch=5.2.0+ox -- dune runtest --force`: both passed, sequentially.
- **Not run:** terminal smoke/visual checks or Tree-sitter probe. Phase 2 has no live
  provider or palette; the phase 1 smoke cursor-timing failures remain unresolved,
  not silently marked successful. No benchmark/performance claim beyond the lookup
  algorithms and dense synthetic correctness tests.

**Next session:** phase 3 only: implement `ches_highlight_ocaml` using the installed
`tree-sitter.0.1.0` and pinned compiled-in grammars, provider-owned parser/query
handles, and Ches-owned predicate-free structural queries from the verified phase 0
approach. Map captures through `Category.of_capture` and construct `Snapshot` with
the caller's key/source. Keep parsers out of frame/core and do not start live cache
integration or palette work. Read earlier query/resource/GC findings and add the
full phase 3 provider fixtures and safe failure handling. Audit disposition remains
as recorded above; technical feasibility does not establish license compliance.

### 2026-10-04 — Phase 3: tested OCaml provider complete

**Status:** implementation complete; owner acceptance separate. Phase 4 live
integration, cache, detection, palette, and phase 5 incremental updates were not
started. Existing phase 1/2 local changes and handoffs were preserved. No mutative
Git operations, installation, switch modifications, downloads, or vendoring.

**Changed files/interfaces:**

- New `highlight_ocaml/dune` defines `ches_highlight_ocaml`, depending on
  `ches_highlight`, Core, `tree-sitter`, and `tree-sitter.ocaml`. The existing exact
  opam dependency remains `tree-sitter.0.1.0`; no package metadata changed.
- New `highlight_ocaml/queries.ml` is a private module containing a shared
  Ches-authored predicate-free query. It compiles independently against both
  bundled grammars. Captures cover keywords, ordinary/quoted/multiline strings,
  characters and escapes, numbers, nested comments, types, modules, constructors,
  properties, variables, operators, punctuation, boolean constants, and structural
  functions: parameterized bindings, direct `fun`/`function` bodies, simple calls,
  and arrow-typed value/external specifications. No semantic name resolution or
  all-capitals/builtin-name heuristics were added. Record braces are structurally
  scoped so quoted-string delimiters remain String under shortest-range precedence.
- New `highlight_ocaml/provider.{ml,mli}` expose an abstract synchronous session,
  `create ~language`, `key ~document ~revision`, `highlight ~key ~source`, and
  idempotent `close`. Results contain only an immutable `Snapshot` and a status:
  `Highlighted { syntax_errors }` or `Plain failure`. Each call resets the parser,
  freshly parses the entire source without `~old`, queries captures and normalizes
  via phase 2's `Snapshot.create`. No nodes, trees, or mutable query/parser handles
  escape. Query cursors/trees are local; the query is passed to every capture call
  to keep it reachable during iteration. There are no global lazy highlighters.
- Provider initialization rejects missing, invalid, or predicate-bearing queries;
  `Failure`/`Invalid_argument` from binding initialization/parsing/querying are
  converted to safe statuses. Key language/configuration mismatch, invalid UTF-8,
  unsupported language, closed sessions, and input beyond the binding's uint32
  byte-length limit return an empty snapshot for the **requested current key**.
  No previous result is retained or reused. Invalid source never enters C.
  Parse/query failure disables the session until explicit recreation; malformed
  syntax trees do not. Process-fatal exceptions are not hidden.
- `highlight/snapshot.{ml,mli}` add only `Key.language` and `Key.configuration`
  accessors, required for checking provider/key compatibility. No phase 2
  normalization, renderer, editing, or theme behavior was changed in this phase.
- New `highlight_ocaml/test/dune` and `highlight_ocaml/test/test_provider.ml` add
  13 provider tests: both query initializations; baseline `.ml`/`.mli` categories;
  structural functions; numeric forms; nested multiline comments; quoted and
  multiline strings; character/string escapes; exact Unicode byte ranges in both
  grammars; unmatched whitespace; empty/incomplete/malformed inputs and recovery;
  unknown/internal capture filtering; missing/invalid/predicate query fallback;
  injected parse failure and session recreation; stale-range prevention and prior
  snapshot immutability; close behavior; key mismatch; UTF-8/uint32 guards; and
  reused-vs-fresh equivalence across unrelated sources and forced GC.
  `Provider.For_testing` exposes query/failure/length seams without exposing any
  native handles; these are not user-query configuration features.
- New `scripts/syntax_provider_probe/{dune,probe.ml}` provide an explicitly invoked
  bounded resource/whole-call latency observation, using a reused provider for 200
  calls per grammar on 500-copy fixtures and checking deterministic normalized
  output. It is not part of tests or editor input; forced GC is probe-only.
- New `highlight_ocaml/ASSETS.md` documents reproducible compiled-in packaging,
  query version, notices/provenance findings, ownership, fallback, limitations,
  and exact commands. Configuration key:
  `tree-sitter.0.1.0/ches-ocaml-structural-v1`. Bump the query version when changing
  highlight behavior. No external query file/runtime search path/network needed.

**Asset/license record:** package release commit and grammar blob identifiers are
the pinned phase 0 findings reproduced in `ASSETS.md`; both grammar ABIs are 15.
Binding ISC, upstream runtime/OCaml grammar MIT and separate Unicode notice remain
as recorded earlier. Exact bundled runtime/grammar upstream revisions and missing
installed notices remain unresolved. No upstream highlight query was copied and
no further audit was performed, following the owner's disposition. This is not
license-compliance approval or a relabeling of the complete bundle as ISC.

**Exact commands/outcomes:**

- `opam list --switch=5.2.0+ox --installed tree-sitter`: confirmed installed 0.1.0.
- `opam exec --switch=5.2.0+ox -- dune build`: passed initially and finally.
- `opam exec --switch=5.2.0+ox -- dune runtest highlight_ocaml/test`: initial run
  failed one quoted-string test because global brace captures produced punctuation
  on delimiters; narrowed braces to record nodes and reran successfully. No policy
  changes or snapshot promotions. Expanded fixtures then passed with
  `opam exec --switch=5.2.0+ox -- dune runtest highlight_ocaml/test --force`.
- `opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_provider_probe/probe.exe`:
  passed twice, before and after adding external-function recognition. Final run:
  `.ml` 19,500 bytes, batch means 6.599 / 6.334 / 6.404 / 6.433 ms per complete
  parse/query/normalize call; `.mli` 23,000 bytes, 6.393 / 6.374 / 6.380 / 6.270 ms.
  These include normal automatic GC during calls, not forced collection between
  individual calls; forced collection occurs before/after each batch of 50.
- Final `.ml` RSS after forced GC: 32,020 KiB before calls, then 43,784 / 43,788 /
  43,788 / 43,792 KiB; after close/GC 43,792 KiB. Subsequent `.mli` RSS in the same
  process: 49,216 KiB before calls, then 49,500 KiB after every batch and close/GC.
  Approximately plateaued RSS is an observation, **not proof of leak freedom or
  prompt native disposal**. The binding's external-memory accounting limitation
  remains; allocator retention and live-editor/larger-file costs are unmeasured.
- Final `opam exec --switch=5.2.0+ox -- dune runtest --force`: full suite passed,
  sequentially after the final build. No test expectations promoted or existing
  snapshots changed.
- Read-only `git status --short`, `git diff --check`, and targeted `git diff`:
  inspected existing work and final changes; whitespace check passed.
- **Not run:** terminal smoke, real-terminal visual review, live-editor parse-count
  tests, or incremental benchmarks. No live rendering/palette changed here; phase 1
  smoke cursor timing failures remain unresolved rather than marked successful.

**Next fresh session:** phase 4 only. Give `Ches_app.Controller` an authoritative
document identity, provider ownership and an immutable snapshot cache. Construct
the current key using `Provider.key`; update after initial load and final text
revision changes, not rendering/movement/scroll/resize/animation/save. Recreate
providers on reload/configuration change or an explicitly authorized retry after
failure; a failed session otherwise stays disabled. Cache empty current results,
do not display stale snapshots, and do not spam or overwrite editor feedback.
Detect only case-sensitive `.ml`/`.mli`, pass `(expected_current_key, snapshot)` to
`Frame.render`, add the modest palette in `ui/theme.ml`, and prove parse counts and
revision freshness in integration tests. Measure live full-parse costs on broader
representative fixtures, run smoke/visual checks as available, then **stop for owner
review before any incremental optimization**.

### 2026-10-04 — Phase 4: live highlighting and revision cache complete; review gate

**Status:** implementation complete; owner/real-terminal acceptance pending.
Phases 0–4 now provide live OCaml highlighting. No incremental edit reporting,
incremental parsing, extra languages, semantic tokens, query/config engine, or
phase 6 documentation sweep was started. Existing phase 1–3 local work and
handoffs were preserved. No mutative Git commands, installs, switch changes,
downloads, or additional asset audit. No repository `AGENTS.md` found; earlier
ancestor checks in this session also found none.

**Changed files/interfaces:**

- New `app/highlighting.{ml,mli}` hold a controller-owned document identity and
  immutable current key/snapshot/status, with a serialized shared runtime owning
  the provider and cumulative parse count. The key contains identity, actual editor
  revision, detected language and `Provider.configuration`. An unchanged key reuses
  the exact snapshot. Changed text gets one whole-document provider call after the
  input's final editor revision, even when the keymap dispatches multiple actions.
  Healthy providers are reused; language changes, successful reloads and retries
  after failures close/recreate them. Unsupported files have an empty current
  snapshot and no provider. Historical snapshots never contain native trees/handles.
- `app/controller.{ml,mli}` create the cache on load/creation, refresh after final
  `handle_input` effects and controller-owned moves, and expose observational
  `highlights`, `highlight_status`, `highlight_parse_count`, and idempotent `close`.
  The effect pipeline records successful reloads explicitly: even identical bytes
  reset the provider and get the core's new revision; failed reloads preserve the
  existing cache and editor error. Exit closes the shared runtime. Native handles
  remain outside pure editor state/history. No key binding, text, revision, history,
  register, dirty/save, or feedback semantics changed.
- `app/dune` adds `ches_highlight` and `ches_highlight_ocaml`; the app remains free
  of terminal, Bonsai and Async dependencies. Screen/core/input do not directly
  execute or acquire parser handles. The provider still uses the existing pinned
  `tree-sitter.0.1.0` package, with no package metadata changes.
- `highlight/language.{ml,mli}` add `of_path`: only case-sensitive `.ml` and `.mli`;
  absent, extensionless and other paths remain Plain. No content sniffing.
- `highlight_ocaml/provider.{ml,mli}` add an observational actual-parse-attempt
  counter; controller diagnostics aggregate it across recreated sessions. It counts
  C parse attempts, not frames/queries/initialization. Failed sessions are still
  disabled until recreated, as in phase 3.
- `screen/frame.{ml,mli}` default to the controller's authoritative cached key and
  snapshot. Explicit synthetic overrides remain supported. Independent snapshot
  key/editor revision rejection and indexed glyph lookup remain intact. Frame/Bonsai
  render performs no provider work; screen remains Bonsai-free.
- `ui/editor_view.ml` also closes the shared runtime when terminal startup/run
  returns, including error returns. Normal Quit/Force_quit close in the controller;
  native reclamation still relies on binding finalizers, not invented delete APIs.
- `ui/theme.{ml,mli}` introduce eight syntax foreground roles: violet keywords,
  green strings, orange numbers, readable gray comments, cyan types/properties,
  blue functions, teal modules, and amber constructors/constants/escapes. Variables,
  operators, punctuation and unmatched text keep the ordinary foreground. No font
  changes. Special-display foreground and existing overlays retain precedence;
  current-line backgrounds and Plain padding are unchanged. `syntax_role` documents
  the category mapping. This is a fixed palette, not a configuration/theme engine.
- New `test/test_highlighting.ml`, updated `test/dune`, and new
  `screen/test/test_live_highlighting.ml` cover initial creation/load and empty/new
  files, exact suffix detection, distinct identities for identical paths, equality
  with fresh-provider ranges after edits/paste/block operations/undo/redo, final-
  revision parse counts including buffered Insert actions, snapshot immutability,
  save byte/dirty behavior, identical/different/failed reloads, test-only language
  changes, safe cached failure and retry, and preserved editor feedback. Headless
  frame tests prove no parse on motion/scroll/resize/animation/search/selection;
  multiline comment insertion above the viewport changes all visible syntax;
  undo/redo restores it; live overlays and geometry remain correct. Language/failure
  test seams do not add production editing commands or file associations.
- `ui/test/test_theme.ml` deliberately replaces the phase 2 temporary all-categories-
  plain assertion with actual syntax-foreground mapping and special/overlay attribute
  precedence across all 360 combinations. Existing plain-style compatibility and
  font tests remain. No existing expect snapshots changed or were promoted.
- New `scripts/syntax_live_probe/{dune,probe.ml}` give a reproducible controller
  latency observation on three actual repository sources and a generated 5,000-line
  fixture. It verifies successful highlights, one parse per text-change event and
  none for 100 subsequent motions. The probe is explicitly invoked, not run in the
  editor or `dune runtest`; timings include synchronous editing/text-buffer work and
  full parse/query/normalization, but not rendering. It uses a headless width function
  and changes only leading ASCII spaces, preserving source syntax.

**Failure/lifetime policy:** provider failures are intentionally silent in the UI;
diagnostic status remains available through the controller. Empty current results
are cached and reused for unchanged keys; frames cannot retry, spam messages or
replace unrelated editor errors. A changed revision or successful reload retries
using a new session. Mutable runtime ownership is shared only across serialized
controller versions, while their presentation snapshots remain immutable; callers
must not continue using a closed runtime or make concurrent provider calls. No
parser object enters editor history or is mutated by rendering. Binding GC/native
memory-accounting limitations recorded in phase 3 remain.

**Exact commands/outcomes:**

- `opam exec --switch=5.2.0+ox -- dune build`: passed after fixing an initial
  warning-as-error for a redundant record `with`, and a new test's reference to an
  unavailable `Sys_unix` module (used `Stdlib.Sys.readdir` instead). No dependencies
  installed and no broad/foreign cleanup operations introduced.
- `opam exec --switch=5.2.0+ox -- dune runtest --force`: full suite passed repeatedly
  after compilation fixes and after strengthening buffered-action/snapshot tests.
  Final build/tests run sequentially; no Dune locking conflicts or promotion.
- `TMPDIR=/tmp/opencode scripts/smoke.sh`: **failed, exit 1, five checks**. Same
  recorded classes as phase 1: tall scrolling cursor row, counted-motion cursor
  row, document-motion cursor row, and two wide-line cursor assertions. Failure
  captures show hidden terminal cursor (`cursor_flag=0`) with smear cells. This is
  consistent with earlier timing failures, not an independently proven comparison
  against a pre-change binary. Other smoke checks passed, including saved bytes,
  controls/wide geometry, block-selection/insert colors, terminal restoration, and
  `.ml` review-screen launches. No animation or smoke-script changes were made.
  Colored review captures: `/tmp/opencode/ches-smoke-screens.Ph6xQS`.
- `opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_live_probe/probe.exe`:
  passed twice. Final observed results (20 leading-space edits per sample):

  | Fixture | Source bytes | Initial controller/parse ms | Mean edit ms | Max edit ms |
  | --- | ---: | ---: | ---: | ---: |
  | `highlight_ocaml/provider.ml` | 5,102 | 16.868 | 1.609 | 2.475 |
  | `core/editor.ml` | 45,859 | 31.010 | 18.999 | 19.848 |
  | `core/text_buffer.mli` | 4,195 | 9.823 | 0.552 | 1.043 |
  | generated OCaml, 5,000 copies | 205,000 | 115.147 | 91.208 | 96.598 |

  Every sample had 21 total parses (initial + 20 changed inputs); 100 later motions
  did not increase counts. These are local observations, not universal latency
  guarantees. Around 90 ms per edit on the 205 KB fixture is a material limitation
  of synchronous full parsing/querying/normalization; large-file typing may lag.
  No optimization was bundled to hide that result. Larger files and interactive
  native-memory growth remain unmeasured; rendering is excluded from these numbers.
- Read-only `git status --short`, targeted `git diff`, and `git diff --check`:
  inspected existing work and changes; whitespace check passed. No Git state
  mutation, commits, staging or pushes.
- **Not performed:** owner real-terminal palette/overlay/flicker acceptance for
  `.ml`, `.mli`, and unsupported files. Automated attribute/headless and tmux smoke
  checks do not replace that review. No incremental measurements/implementation.

**Required next action: owner review, not automatic phase 5.** Try the current
editor on `highlight_ocaml/provider.ml`, `core/text_buffer.mli`, and `README.md`
to compare both supported languages with plain-text fallback. Review readability
under search/current match, all selections, insert points, cursor-line fill,
controls/wide/combining characters, typing/paste/scroll/resize and smear animation.
Confirm acceptance or request a bounded palette/correctness correction. Separately
decide whether to authorize phase 5 optimization or explicitly defer it and proceed
to phase 6 regression/documentation. Smoke cursor timing failures remain a known
follow-up; do not mark them resolved without checking. **Stopped at the phase 4 gate.**
