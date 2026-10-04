# Ches syntax highlighting — phased implementation plan

**Status (2026-10-04):** phase 0 technical feasibility verified; owner declined
further bundled-asset provenance/license investigation (“don't care”), so that
unresolved audit is no longer an implementation gate. This is not a finding of
license compliance. Phase 1 in progress; phases 2–6 have not started.

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
