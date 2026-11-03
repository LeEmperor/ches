# Snippet collections and hardware-development catalog

Status: initial implementation delivered 2026-11-03; original ideas and remaining
work are retained below. Ticket IDs are local planning references, not GitHub
issues. See the [user guide](../snippets.md) for shipped behavior.

## Implementation checkpoint

- SNIP-01: implemented optional single collection membership, parent toggles,
  last-matching-toggle precedence, all-enabled defaults, and backward-compatible
  configuration/legacy JSON loading. IDs remain independent of membership.
- SNIP-02–08: shipped an initial catalog of 93 templates: 28 SV design, 10 SV
  verification, 11 core OCaml, 3 testing, 6 Jane Street, 24 Hardcaml design, and
  11 Hardcaml verification. Xilinx terms are searchable cross-references to
  generic RTL; primitive instantiation and trigger aliases remain future choices.
- SNIP-09: collection search and row/preview display implemented. Project-specific
  activation, dedicated filter controls, tags, and aliases remain deferred.
- SNIP-10: parser/expansion, linked editing, collection behavior, configuration,
  and picker tests pass. Hardcaml APIs were checked against the installed v0.18
  preview and representative code type-checked. SV simulator/linter validation
  and real-workflow acceptance remain follow-ups.
- Verification: `dune build -j 10 @all`, `dune runtest -j 10`, then focused
  `dune runtest -j 8 completion/test` after the searchable vocabulary addition.

The proposal sections below preserve the design discussion; the checkpoint above
and current guides take precedence when describing implemented behavior.

## Direction from discussion

- Expand SystemVerilog first, building on the existing `aff`, `acomb`, `mod`,
  `inst`, and `genfor` starters. Short, memorable abbreviations are desirable.
- Organize SV into **design** and **verification** collections.
- Distinguish core OCaml, testing, Jane Street ecosystem, and Hardcaml templates.
- Split Hardcaml into design and verification too. Prefer direct `Signal` usage
  for the main path, while offering a broad range of patterns to experiment with,
  including the Always DSL.
- OCaml and Hardcaml share language/file scopes; collections describe purpose,
  not a new Hardcaml file type.
- Explore links to Xilinx register terminology such as FDRE, both for discovery
  and potentially for trigger aliases. Do not assume a behavioral RTL template
  guarantees a particular FPGA primitive mapping.

## Current foundation and boundaries

The [configuration API](../configuration.md#snippets) supports stable IDs,
prefixes, descriptions, language/extension scopes, overrides, and disabling
individual IDs. The [snippet picker](../plans/snippet_discovery.md) searches
prefix, description, and ID and previews the body and origin.

Linked fields, choices, filename-backed defaults, indentation, and grouped undo
already exist; see [snippet controls](../editor_reference.md#snippet-placeholders).
Collection metadata and toggles are now implemented. Project activation, tags,
and trigger aliases remain proposals. Templates should fit the existing
bounded parser rather than depend on transforms or nested numbered fields.

## Proposed organization

| Collection | Scope | Purpose |
| --- | --- | --- |
| `sv.design` | SystemVerilog | Synthesizable RTL structures and declarations |
| `sv.verification` | SystemVerilog | Assertions, simulation, and testbench scaffolds |
| `ocaml.core` | OCaml | General language structures |
| `ocaml.testing` | OCaml | Test scaffolds, including expect tests |
| `ocaml.jane-street` | OCaml | Base/Core and related ecosystem conventions |
| `hardcaml.design` | OCaml | Interfaces, Signal-first circuits, hierarchy, and optional Always patterns |
| `hardcaml.verification` | OCaml | Cycle simulation, stimulus, checks, and waveforms |

An implementation may use these as leaf collections with parent filters such as
`hardcaml` or `sv`; parent enable/disable semantics need an explicit decision.
Collection identity should be independent of stable snippet IDs so that moving a
template does not break user overrides. Preserve existing `sv.*` starter IDs.

Use distinctive Hardcaml triggers (`hci`, `hco`, `hccreate`, `hcreg`, etc.) to
avoid crowding ordinary OCaml completions. All new triggers below are candidates,
not finalized bindings. Prefer several explicit useful variants over a single
template with a long sequence of structural choices. Use choices for small local
variations such as edge selection.

## Ticket index

| Ticket | Priority | Work |
| --- | --- | --- |
| SNIP-01 | First | Collection metadata and compatibility design |
| SNIP-02 | First | SV design starter expansion |
| SNIP-03 | First | Register vocabulary and Xilinx cross-references |
| SNIP-04 | First | SV verification starter expansion |
| SNIP-05 | Next | Core OCaml structural templates |
| SNIP-06 | Next | OCaml testing and Jane Street templates |
| SNIP-07 | Next | Signal-first Hardcaml design templates |
| SNIP-08 | Next | Hardcaml verification templates |
| SNIP-09 | Later | Collection discovery and project activation |
| SNIP-10 | Alongside catalog work | Template acceptance and real-use review |

Content work can begin under existing IDs/descriptions before collection UI lands.

## SNIP-01 — Collection metadata and compatibility

Define how a snippet belongs to a collection, how users enable/disable a
collection, and how bundled and personal templates participate. Keep scope
(language applicability), collection (purpose), and origin (provenance) separate.

Acceptance:

- Specify the configuration API and default enabled collections; do not present
  a hypothetical API as available today.
- Existing declarations without collection metadata and legacy JSON still work.
- Preserve stable ID overrides and document how collection toggles interact with
  individual adds/disables and bundled → JSON → OCaml layering.
- Decide whether membership is single or multiple and whether parent collection
  toggles include children. Define deterministic behavior for conflicting toggles.
- Catalog/settings reload remains coherent and rejects invalid configuration
  without replacing the last good state.

## SNIP-02 — SV design starter expansion

| Pattern | Candidate trigger | Useful fields / behavior |
| --- | --- | --- |
| Synchronous-reset register | `affr` | Clock, reset, destination, reset value, next value |
| Asynchronous-reset register | `affar` | Clock/reset edges, reset signal, destination and values |
| Synchronous reset plus enable | `affre` | Reset first, then enable; no assignment means hold |
| Enable-only register | `affe` | Clock, enable, destination, next value |
| Combinational block with defaults | `acombd` | Default assignments before override logic |
| Unique case | `ucase` | Selector, branch labels, explicit default branch |
| Packed struct | `pstruct` | Type name and editable member body |
| Enum | `enum` | Base type/width, type name, editable states |
| Vector typedef | `tvec` | Width and type name |
| Parameterized module | `modp` | Filename-backed name, parameter list, ports, body |
| Local parameter | `lparam` | Type, name, value |
| Vector declaration | `logicv` | Width and signal name |
| Conditional generate | `genif` | Condition, named block, body |
| Named generate loop | existing `genfor` | Review existing linked index and naming before adding a duplicate |
| FSM pieces / full scaffold | `fsm`, `fsmnext`, `fsmreg` | Enum, next-state defaults/case, state register |

Acceptance: document reset polarity/timing and enable priority; link repeated
signal names; leave useful final cursor positions; keep existing starters
compatible. FSM templates must make encoding and default/recovery policy explicit
rather than silently choosing one-hot encoding or a recovery scheme. Review
whether abbreviated reset variants need clearer descriptions or additional
active-low variants. Do not automatically expose SV-only constructs in Verilog.

## SNIP-03 — Register vocabulary and Xilinx cross-references

Explore searchable terminology and optional aliases for familiar primitive names:

| Term | Behavior to investigate for a corresponding RTL template |
| --- | --- |
| FDRE | D flip-flop with clock enable and synchronous reset |
| FDSE | D flip-flop with clock enable and synchronous set |
| FDCE | D flip-flop with clock enable and asynchronous clear |
| FDPE | D flip-flop with clock enable and asynchronous preset |

Acceptance:

- Verify exact control priority, polarity, initialization, and device-family
  details against the relevant AMD/Xilinx primitive documentation before shipping
  a named correspondence. Record the references with the eventual templates.
- Distinguish generic behavioral RTL from explicit vendor primitive
  instantiation. Decide whether vendor instantiations deserve an optional
  vendor-specific collection rather than inclusion in generic `sv.design`.
- Start with searchable descriptions/IDs where possible; decide whether aliases
  add enough value to justify catalog support. Avoid duplicate picker entries
  for aliases of the same template.
- Consider analogous terminology in Hardcaml register descriptions, while
  preserving its API semantics and avoiding claims about synthesis mapping.

## SNIP-04 — SV verification starter expansion

Candidate templates:

- Clock generator (`tbclk`), reset sequence (`tbrst`), simulation timeout
  (`tbtimeout`), and waveform dump setup (`tbdump`).
- Small testbench module (`tb`) with DUT instance and space for stimulus/checks.
- Clocked concurrent assertion (`sva`), named property (`prop`), and cover
  property (`coverp`), with clock and optional reset-disable condition.
- Common property shapes such as implication and bounded response, with timing
  choices visible and explained rather than hidden in an opaque shorthand.

Acceptance: distinguish simulation-only templates from design templates; state
time units/precision assumptions, simulator-specific waveform behavior, assertion
sampling, reset-disable behavior, and overlapping/nonoverlapping implication.
Keep clocks/resets consistent in a full testbench and use useful linked fields.
Larger UVM/class-based suites remain a future decision, not a first-batch dependency.

## SNIP-05 — Core OCaml structural templates

Candidates: module/struct, module type/signature, functor, record, variant,
abstract interface type, `val`, labeled-argument function, recursive function,
and pattern-matching function. Consider deriving clauses as editable additions,
with their PPX dependencies identified rather than implied to be core syntax.

Acceptance: favor structural boilerplate over very short expansions; review
`.ml` versus `.mli` applicability; keep generic templates independent of Base,
Core, and Hardcaml. Select a consistent abbreviation scheme before bundling.

## SNIP-06 — OCaml testing and Jane Street ecosystem

Candidates: `let%expect_test`, `let%test_unit`, sexp conversion/deriving patterns,
Result/Or_error handling, and Core Command scaffolds. Keep testing templates in
`ocaml.testing` even when they rely on ecosystem packages; describe dependencies
and allow collections to be enabled together without duplicate entries.

Acceptance: pick conventions based on representative user code; distinguish
Base and Core APIs; identify required libraries/PPXs. Error handling templates
should express the intended return type and not silently introduce exceptions.

## SNIP-07 — Signal-first Hardcaml design

| Pattern | Candidate trigger | Intended scaffold |
| --- | --- | --- |
| Input / output interface | `hci`, `hco` | `I` / `O`, polymorphic record, width attributes, hardcaml deriving |
| Interface field | `hcfield` | Record field with editable bit width |
| Create function | `hccreate` | Usual scope and input/output interface conventions |
| Complete circuit module | `hccircuit` | Interfaces plus a Signal-first implementation body |
| Register / register spec | `hcreg`, `hcregspec` | Clock/reset/enable conventions and editable data |
| Pipeline | `hcpipe` | Depth, input, and relevant control arguments |
| Combinational structures | To choose | Mux, select/concatenate, wire/naming patterns where useful |
| Hierarchy | `hchier` | Standard scoped hierarchical instantiation wrapper |
| RTL generation | `hcrtl` | Common RTL-output entry point and backend selection |
| Always DSL alternatives | `hcavar`, `hcaif`, `hcaswitch`, `hcaseq` | Variables, conditional/switch, sequential compilation patterns |

Acceptance: use direct `Signal` expressions for the primary scaffolds. Provide
Always patterns as clearly labeled alternatives for experimentation. Confirm
the user's library version, opens, scope/naming conventions, interface deriving,
reset conventions, and hierarchical wrapper against real modules before fixing
template bodies. Do not guess function signatures. Link repeated interface and
signal names, and keep larger scaffolds navigable with a reasonable field count.

## SNIP-08 — Hardcaml verification

Candidates: cycle simulator creation, input/output handle binding, input
stimulus, stepping/reset sequences, output checks, an expect-test skeleton,
and optional waveform capture/display. Combine selected pieces into a small
simulation-test scaffold after their individual forms prove useful.

Acceptance: validate APIs against the selected Hardcaml version; make pre/post
clock observation timing clear; identify optional waveform/test dependencies;
support testing Signal-first designs without requiring the Always DSL. Keep
simulation helpers distinct from synthesizable design patterns.

## SNIP-09 — Discovery and project activation

- Show collection identity in picker rows/previews and support collection search
  or filters, including design/verification and a parent Hardcaml view.
- Enable or disable whole collections and select collections explicitly per
  project; decide how project settings compose with user settings and reload.
- Prefer explicit activation initially. Content-based Hardcaml detection is an
  optional later experiment, not necessary for ordinary `.ml` files to work.
- Consider tags/cross-references for FPGA terminology and optional aliases.
- Organize template sources by collection for maintenance without requiring each
  source file to become a separate language scope.

Acceptance: a user can find Hardcaml verification templates without remembering
their triggers; disabled collections do not appear in completion or the picker;
scope restrictions still apply. Distinguish picker filtering from disabling a
collection. Defaults and project precedence require a documented decision.

## SNIP-10 — Acceptance and real-use review

For each batch, review expansion at representative indentation, linked fields,
choice behavior, final cursor, undo, and picker discoverability. Use meaningful
catalog/parser tests where behavior needs coverage and compile/lint representative
expanded examples with the relevant toolchain where available. Do not claim
syntax validation from inspecting the raw snippet body alone.

Try templates in actual design and verification work before expanding the suite
further. Record which snippets save editing, which need too many field stops,
which abbreviations collide, and whether richer snippet interaction is needed.
Prioritize SV design/register vocabulary and small verification patterns first,
then OCaml/Hardcaml structural templates, then larger combined scaffolds.

## Open decisions for implementation

1. Exact collection API, shipped defaults, parent behavior, and project precedence.
2. Final trigger spelling and whether aliases are needed beyond searchable text.
3. Preferred reset polarity/style and which register variants deserve shortcuts.
4. Generic RTL versus optional explicit FPGA primitive templates.
5. Representative Hardcaml modules and library version for concrete bodies.
6. Which simulation/waveform tools and Jane Street conventions to target first.
