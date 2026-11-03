# Snippet collections

[Documentation index](README.md) · [Configuration](configuration.md#snippets) ·
[Field controls](editor_reference.md#snippet-placeholders)

Ches bundles 93 templates in seven collections. All collections are enabled by
default. File scopes still apply: SV templates appear in `.sv`/`.svh`, while
OCaml and Hardcaml share OCaml files. Implementation-only OCaml templates are
restricted to `.ml`; declarations intended for interfaces also appear in `.mli`.

Open **Insert snippet** from the command palette (`Space c c`) to browse. Search
by trigger, description, ID, or collection name, such as `sv.verification` or
`hardcaml.design`. Rows and previews show collection identity. Picker search
filters the view; it does not enable or disable templates. Alternatively, type a
trigger in Insert mode and accept its completion with Enter to activate fields.

## Choose collections

In `config.ml`:

```ocaml
open Ches_config

let () =
  Snippets.set_collection_enabled ~collection:"hardcaml" false;
  Snippets.set_collection_enabled ~collection:"hardcaml.design" true;
  Snippets.set_collection_enabled ~collection:"sv.verification" false
```

Choose **Reload configuration** after saving. This example keeps Hardcaml design
but hides its verification templates and SV verification templates from both
completion and the picker. Disabled templates cannot be inserted by ID either.

- Each template belongs to at most one optional collection. Untagged templates
  are always collection-enabled, subject to their file scope and individual ID.
- A parent name matches dotted descendants: `hardcaml` matches
  `hardcaml.design` and `hardcaml.verification`, not `hardcaml-other`.
- The **last matching toggle wins**, even if it names a parent rather than a more
  specific child. Names are case-sensitive. Unknown valid names are allowed for
  user collections.
- Toggles preserve definitions, so a later `true` restores availability.
  `Snippets.disable ~id` removes a definition instead. Re-enabling a collection
  does not restore an individually removed ID; a later `Snippets.add` can.
- Adds/overrides carry their own metadata. An override without `~collection` is
  untagged; it does not inherit the old definition's membership.
- Collection names use nonempty dot-separated ASCII letters, digits, `_`, or `-`.
- Reload evaluates a fresh configuration, so removing a toggle restores the
  default behavior. Settings, definitions, and toggles are validated together.

Project-specific activation and separate alias triggers are not implemented.
Use the shared `config.ml` to select collections and the picker to narrow a search.

## SystemVerilog design — `sv.design` (28)

| Triggers | Templates |
| --- | --- |
| `aff`, `acomb`, `mod`, `inst`, `genfor` | Original clocked/combinational blocks, module, instance, generate loop |
| `affr`, `affrn` | Synchronous reset, active high / active low |
| `affar`, `affarn` | Asynchronous reset, active high / active low |
| `affe` | Enable-only register, holding when disabled |
| `affre` | Synchronous active-high reset before enable |
| `affare`, `affarne` | Asynchronous reset before enable, active high / active low |
| `affse`, `affce`, `affpe` | Synchronous set / asynchronous clear / asynchronous preset, before enable |
| `acombd`, `ucase` | Combinational defaults and unique case with default branch |
| `pstruct`, `enum`, `tvec`, `logicv`, `lparam` | Packed struct, enum, vector typedef/declaration, typed local parameter |
| `modp`, `genif` | Parameterized module and named conditional generate |
| `fsm`, `fsmnext`, `fsmreg` | Complete FSM, next-state logic, state register |

Register variants use a rising-edge clock and active-high enable where present.
Reset/set/clear takes priority over enable; disabled registers hold their values.
Reset-value fields default to `'0`; set/preset variants use all ones (`'1`).
`aff` retains its selectable rising/falling edge.

Search the picker for **FDRE**, **FDSE**, **FDCE**, or **FDPE** to find `affre`,
`affse`, `affce`, or `affpe` respectively. These are generic behavioral RTL
patterns with related control vocabulary, not vendor primitive instances or a
promise of synthesis mapping. They omit vendor initialization, GSR, inversion,
timing, and X/Z behavior. References: [AMD UG953 FDRE](https://docs.amd.com/r/en-US/ug953-vivado-7series-libraries/FDRE)
and the [published Xilinx primitive models](https://github.com/Xilinx/XilinxUnisimLibrary/tree/master/verilog/src/unisims).

The full FSM uses explicit binary encoding, synchronous active-high reset, hold
by default, and recovery to the initial state for an unmatched state. Review
those policies, enum width, and values when adapting it. `fsmnext` also includes
explicit hold/recovery behavior. These templates are editable scaffolds, not
decisions about the intended state machine.

## SystemVerilog verification — `sv.verification` (10)

| Triggers | Templates |
| --- | --- |
| `tbclk`, `tbrst` | Clock generator and active-high reset sequence |
| `tbtimeout`, `tbdump` | Fatal timeout and simulator-dependent VCD dump |
| `tb` | Testbench with linked clock/reset/DUT fields and timeout |
| `sva`, `prop`, `coverp` | Concurrent assertion, named property/assertion, cover property |
| `svaimp`, `svabound` | Selectable implication and bounded response |

The testbench declares `timeunit 1ns` and `timeprecision 1ps`. Standalone timing
fragments use explicit literals such as `5ns`; the enclosing precision must
resolve them. Reset is held across rising edges and released on a falling edge;
the testbench leaves stimulus on falling edges to avoid racing rising-edge RTL.
Sample checks after DUT updates. VCD system-task support depends on the simulator.

Assertions sample at the rising edge. `disable iff (rst)` disables asynchronously;
use `0` for no reset-disable condition. In `svaimp`, `|->` starts the consequent
at the antecedent's sampled cycle, while `|=>` starts it on the next sampled
cycle. `svabound` uses inclusive `##[MIN:MAX]` bounds measured from that sample.

## OCaml collections (20)

| Collection | Triggers | Dependencies / purpose |
| --- | --- | --- |
| `ocaml.core` (11) | `ocmod`, `ocsig`, `ocmoddecl`, `ocfunctor`, `ocrecord`, `ocvariant`, `ocabstract`, `ocval`, `ocfun`, `ocrec`, `ocfunction` | Language structures without PPXs; module declaration and abstract type are `.mli`-only |
| `ocaml.testing` (3) | `ocexpect`, `octestunit`, `octesteq` | Expect/unit tests and typed equality assertions |
| `ocaml.jane-street` (6) | `ocsexp`, `ocprintsexp`, `ocresult`, `ocorerror`, `ocerrortag`, `occommand` | Sexp, explicit Result/Or_error handling, Core Command scaffold |

Expect tests need `ppx_expect` and inline tests; unit tests need `ppx_inline_test`.
Typed equality needs the relevant assertion/comparison PPXs and Base/Core.
Descriptions identify the required sexp/let PPXs and opens for ecosystem snippets.
The Command scaffold uses `core_unix.command_unix` and includes the executable's
`Command_unix.run` entry point. No dependency or `dune` stanza is added for you.

## Hardcaml design — `hardcaml.design` (24)

| Triggers | Templates |
| --- | --- |
| `hci`, `hco`, `hcfield` | Input/output interfaces and a record-field fragment |
| `hccreate`, `hccircuit` | Signal-first scoped create and complete register module |
| `hcregspec`, `hcregspecreset` | Synchronous clear / asynchronous reset register specs |
| `hcreg`, `hcregen`, `hcregreset`, `hcregclear` | Plain/enabled register and explicit reset/clear values |
| `hcpipe` | Enabled pipeline |
| `hcmux`, `hcselect`, `hcconcat`, `hcwire`, `hcname` | Mux, slice, concatenate, wire/driver, scope-local naming |
| `hchier`, `hcrtl` | Hierarchical wrapper and Verilog/VHDL output to stdout |
| `hcavar`, `hcawire`, `hcaif`, `hcaswitch`, `hcaseq` | Optional Always DSL variables, conditionals, switch, sequential compilation |

Primary templates use `Signal` directly. Interface/circuit templates use
`ppx_hardcaml`, `I`/`O`, scoped naming, rising-edge registers, and active-high
synchronous `clear`. `hccreate` expects existing compatible interfaces;
`hccircuit` supplies them. `hcfield` is a fragment to insert after a first record
field. Expression fragments assume the surrounding opens/variables described in
their picker descriptions.

Hardcaml distinguishes synchronous **clear** from asynchronous **reset**.
`hcregspecreset` offers an explicit reset level. A `reset_to` is `Bits.t`, whereas
`clear_to` is `Signal.t`. Register priority is reset, then clear, then enable.
Always templates are alternatives, not prerequisites for the Signal-first path.

## Hardcaml verification — `hardcaml.verification` (11)

| Triggers | Templates |
| --- | --- |
| `hcsim`, `hchandles` | Typed Cyclesim creation and input/output refs |
| `hcdrive`, `hcstep` | Width-aware integer stimulus and full simulator cycles |
| `hcreset`, `hcclear` | Internal simulator reset / synchronous DUT clear pulse |
| `hccheck`, `hcbefore` | Output assertion and explicit pre-edge observation |
| `hcexpect` | Register-design expect-test scaffold |
| `hcwave`, `hcwaveprint` | Wave capture and optional waveform printing |

Output handles default explicitly to `After` the clock edge. `hcbefore` exposes
the check/before/at/after phases for pre-edge observation. `hcreset` resets
simulator state; it is not a synchronous clear pulse. `hcclear` advances one
asserted-clear cycle and one released cycle. `hcdrive` truncates its integer to
the current input width. The default expect example assumes an eight-bit d/q
register; adapt the expected bit string when changing widths or stimulus.

Use the **returned wrapped simulator** from `hcwave` for subsequent cycles.
Capture uses Hardcaml itself; `hcwaveprint` additionally needs
`hardcaml_waveterm`. Hardcaml templates were checked against the installed
`v0.18~preview.130.106+341` APIs, with representative expanded code type-checked.
Other versions may require adapting the templates through ordinary ID overrides.

## Extend the catalog

```ocaml
let () =
  Snippets.add
    ~id:"personal.hardcaml-note"
    ~prefix:"hcnote"
    ~scope:["ocaml"]
    ~collection:"hardcaml.design"
    ~description:"Hardcaml design note"
    {snippet|(* ${1:Design intent} *)
$0|snippet}
```

IDs are visible in the picker preview. SV IDs are `sv.<trigger>`; OCaml and
Hardcaml IDs are independent descriptive names, so inspect the preview rather
than deriving an ID from the abbreviation. Use the same ID to override a bundled
template, or `Snippets.disable ~id` to remove it. See the
[backlog](backlog/snippet_collections.md) for remaining project activation and
catalog-review work.
