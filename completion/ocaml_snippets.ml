(* Hardcaml API baseline: installed v0.18~preview.130.106+341 (including
   hardcaml_waveterm). Checked against the installed sources under
   $OPAM_SWITCH_PREFIX/lib/hardcaml:
   kernel/{reg_spec_intf,signal_intf,comb_intf,always_intf}.ml,
   {scope,hierarchy,circuit}.mli, {cyclesim_intf,rtl_intf}.ml;
   hardcaml_waveterm/kernel/waveform_intf.ml. Interface deriving examples:
   /home/wayne/devel/jane/hardcaml/docs/module_interface.md.

   Raw strings preserve snippet escapes, not just OCaml escapes. In particular
   a literal OCaml backslash must be doubled for the snippet parser. Numbered
   fields are deliberately flat; repeated identifiers use linked tabstops. *)

let make ~collection ~scopes id prefix description body : Snippet_definition.t =
  { id = collection ^ "." ^ id; prefix; scopes; collection; description; body }
;;

let core = make ~collection:"ocaml.core" ~scopes:[ ".ml"; ".mli" ]
let core_ml = make ~collection:"ocaml.core" ~scopes:[ ".ml" ]
let testing = make ~collection:"ocaml.testing" ~scopes:[ ".ml" ]
let jane = make ~collection:"ocaml.jane-street" ~scopes:[ ".ml" ]
let design = make ~collection:"hardcaml.design" ~scopes:[ ".ml" ]
let verification = make ~collection:"hardcaml.verification" ~scopes:[ ".ml" ]

let all =
  [ core_ml "module" "ocmod" "OCaml module implementation (stdlib only)"
      {snippet|module ${1:M} = struct
  ${2:let value = ()}
  $0
end|snippet}
  ; core "signature" "ocsig" "OCaml named module type signature (stdlib only)"
      {snippet|module type ${1:S} = sig
  type t

  val ${2:create} : ${3:unit -> t}
  $0
end|snippet}
  ; make ~collection:"ocaml.core" ~scopes:[ ".mli" ]
      "module-declaration" "ocmoddecl" "OCaml module declaration in an interface"
      {snippet|module ${1:M} : sig
  type t

  val ${2:create} : ${3:unit -> t}
  $0
end|snippet}
  ; core_ml "functor" "ocfunctor" "OCaml functor implementation; supply module type S"
      {snippet|module ${1:Make} (${2:X} : ${3:S}) = struct
  type t = $2.t

  $0
end|snippet}
  ; core "record" "ocrecord" "OCaml record type; no PPX dependency"
      {snippet|type ${1:t} =
  { ${2:name} : ${3:string}
  ; ${4:value} : ${5:int}
  }
$0|snippet}
  ; core "variant" "ocvariant" "OCaml variant type; no PPX dependency"
      {snippet|type ${1:t} =
  | ${2:Empty}
  | ${3:Value} of ${4:int}
$0|snippet}
  ; make ~collection:"ocaml.core" ~scopes:[ ".mli" ]
      "abstract-type" "ocabstract" "OCaml abstract interface type and constructor signature"
      {snippet|type ${1:t}

val ${2:create} : ${3:unit} -> $1
$0|snippet}
  ; core "val" "ocval" "OCaml value signature; inside sig or .mli"
      {snippet|val ${1:map} : ${2:t} -> f:(${3:elt} -> $3) -> $2
$0|snippet}
  ; core_ml "labeled-function" "ocfun" "OCaml labeled-argument function (stdlib only)"
      {snippet|let ${1:apply} ~${2:f} ${3:value} =
  ${4:f value}
;;
$0|snippet}
  ; core_ml "recursive-function" "ocrec" "OCaml recursive list traversal (stdlib only)"
      {snippet|let rec ${1:map} ~${2:f} = function
  | [] -> []
  | ${3:x} :: ${4:xs} -> $2 $3 :: $1 ~$2 $4
;;
$0|snippet}
  ; core_ml "matching-function" "ocfunction" "OCaml pattern-matching function over option (stdlib only)"
      {snippet|let ${1:value_or} ~${2:default} = function
  | None -> $2
  | Some ${3:value} -> $3
;;
$0|snippet}
  ; testing "expect" "ocexpect" "Expect test; ppx_expect, inline_tests; prints via Stdlib"
      {snippet|let%expect_test "${1:description}" =
  ${2:Stdlib.print_endline "hello"};
  [%expect {|${3:hello}|}]
;;
$0|snippet}
  ; testing "test-unit" "octestunit" "Unit test; ppx_inline_test, inline_tests; no Base/Core required"
      {snippet|let%test_unit "${1:description}" =
  let ${2:actual} = ${3:1 + 1} in
  assert ($2 = ${4:2})
;;
$0|snippet}
  ; testing "test-eq" "octesteq" "Typed equality assertion; ppx_assert and ppx_compare (ppx_jane), open Base/Core"
      {snippet|[%test_eq: ${1:int}] (${2:actual}) (${3:expected});
$0|snippet}
  ; jane "sexp-record" "ocsexp" "Sexp record conversion; ppx_sexp_conv (ppx_jane), open Base/Core"
      {snippet|type ${1:t} = { ${2:value} : ${3:int} }
[@@deriving sexp]
$0|snippet}
  ; jane "sexp-print" "ocprintsexp" "Print typed sexp; open Core, ppx_sexp_value (ppx_jane)"
      {snippet|print_s [%sexp (${1:value} : ${2:t})];
$0|snippet}
  ; jane "result-match" "ocresult" "Result handling; returns Result, propagates Error without raising; stdlib constructors"
      {snippet|match ${1:result} with
| Ok ${2:value} -> Ok (${3:value})
| Error ${4:error} -> Error $4
$0|snippet}
  ; jane "or-error-bind" "ocorerror" "Or_error-returning function; open Base/Core, ppx_let; errors propagate without raising"
      {snippet|let ${1:run} ${2:input} : ${3:unit} Or_error.t =
  let open Or_error.Let_syntax in
  let%bind ${4:value} = ${5:validate input} in
  ${6:Or_error.return ()}
;;
$0|snippet}
  ; jane "or-error-tag" "ocerrortag" "Add context to Or_error without raising; open Base/Core"
      {snippet|Or_error.tag (${1:result}) ~tag:"${2:context}"$0|snippet}
  ; jane "command" "occommand" "CLI scaffold; open Core, core_unix.command_unix, ppx_let (ppx_jane); Command_unix.run is executable entry point"
      {snippet|let command =
  Command.basic
    ~summary:"${1:description}"
    (let open Command.Let_syntax in
     let%map_open ${2:path} = anon ("${3:PATH}" %: string) in
     fun () ->
       ${4:print_endline path})
;;

let () = Command_unix.run command
$0|snippet}
  ; design "input-interface" "hci" "Hardcaml input interface; open Hardcaml, ppx_hardcaml; rising clock, active-high synchronous clear"
      {snippet|module I = struct
  type 'a t =
    { clock_i : 'a
    ; clear_i : 'a
    ; ${1:d_i} : 'a [@bits ${2:8}]
    }
  [@@deriving hardcaml]
end
$0|snippet}
  ; design "output-interface" "hco" "Hardcaml output interface; open Hardcaml, ppx_hardcaml"
      {snippet|module O = struct
  type 'a t =
    { ${1:q1_o} : 'a [@bits ${2:8}]
    ; ${3:q2_o} : 'a [@bits ${4:8}]
    }
  [@@deriving hardcaml]
end
$0|snippet}
  ; make ~collection:"hardcaml.design" ~scopes:[ ".ml"; ".mli" ]
      "interface-field" "hcfield" "Hardcaml polymorphic record field fragment; ppx_hardcaml; insert after first field"
      {snippet|; ${1:data} : 'a [@bits ${2:8}]$0|snippet}
  ; design "create" "hccreate" "Signal-first create; open Hardcaml, existing I/O with d/q; scope-local names, synchronous clear"
      {snippet|let create scope (i : Signal.t I.t) : Signal.t O.t =
  let open Signal in
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let ${1:q} = reg spec i.${2:d} -- "$1" in
  { O.$1 = $1 }
;;
$0|snippet}
  ; design "circuit" "hccircuit" "Complete Signal-first register module; hardcaml + ppx_hardcaml; rising clock, active-high synchronous clear to zero"
      {snippet|module ${1:Register} = struct
  open Hardcaml

  module I = struct
    type 'a t =
      { clock : 'a
      ; clear : 'a
      ; d : 'a [@bits ${2:8}]
      }
    [@@deriving hardcaml]
  end

  module O = struct
    type 'a t = { q : 'a [@bits $2] }
    [@@deriving hardcaml]
  end

  let create scope (i : Signal.t I.t) : Signal.t O.t =
    let open Signal in
    let ( -- ) = Scope.naming scope in
    let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
    let q = reg spec i.d -- "q" in
    { O.q = q }
  ;;

  $0
end|snippet}
  ; design "reg-spec-clear" "hcregspec" "Register spec; open Hardcaml; rising clock, active-high synchronous clear (not async reset)"
      {snippet|let ${1:spec} = Signal.Reg_spec.create ~clock:${2:i.clock} ~clear:${3:i.clear} () in
$0|snippet}
  ; design "reg-spec-reset" "hcregspecreset" "Register spec; open Hardcaml; rising clock, asynchronous reset; explicit active level"
      {snippet|let ${1:spec} =
  Signal.Reg_spec.create ~clock:${2:i.clock} ~reset:${3:i.reset}
    ~reset_level:${4|High,Low|} ()
in
$0|snippet}
  ; design "register" "hcreg" "Signal register; open Hardcaml; spec supplies reset/clear, default zero values"
      {snippet|let ${1:q} = Signal.reg ${2:spec} ${3:i.d} in
$0|snippet}
  ; design "register-enable" "hcregen" "Enabled Signal register; open Hardcaml; reset then clear then enable priority, disabled holds"
      {snippet|let ${1:q} = Signal.reg ~enable:${2:i.enable} ${3:spec} ${4:i.d} in
$0|snippet}
  ; design "register-reset-value" "hcregreset" "Signal register async reset value is Bits.t; spec must contain reset; open Hardcaml"
      {snippet|let ${1:q} =
  Signal.reg ~reset_to:(Bits.of_int_trunc ~width:${2:8} ${3:0})
    ${4:spec} ${5:i.d}
in
$0|snippet}
  ; design "register-clear-value" "hcregclear" "Signal register synchronous clear value is Signal.t; spec must contain clear; open Hardcaml"
      {snippet|let ${1:q} =
  Signal.reg ~clear_to:(Signal.of_int_trunc ~width:${2:8} ${3:0})
    ${4:spec} ${5:i.d}
in
$0|snippet}
  ; design "pipeline" "hcpipe" "Signal pipeline; open Hardcaml; n enabled register stages, spec supplies reset/clear"
      {snippet|let ${1:pipelined} =
  Signal.pipeline ~enable:${2:i.enable} ${3:spec} ~n:${4:2} ${5:i.d}
in
$0|snippet}
  ; design "mux2" "hcmux" "Signal mux; open Hardcaml; one-bit selector, true input first, equal-width branches"
      {snippet|let ${1:selected} = Signal.mux2 ${2:i.select} ${3:i.a} ${4:i.b} in
$0|snippet}
  ; design "select" "hcselect" "Signal slice; open Hardcaml; inclusive high/low bit indices"
      {snippet|let ${1:byte} = Signal.select ${2:i.data} ~high:${3:7} ~low:${4:0} in
$0|snippet}
  ; design "concat" "hcconcat" "Signal concatenate; open Hardcaml; most-significant input first"
      {snippet|let ${1:packed} = Signal.concat_msb [ ${2:high}; ${3:low} ] in
$0|snippet}
  ; design "wire" "hcwire" "Signal wire and driver; open Hardcaml; matching widths, avoid combinational feedback"
      {snippet|let ${1:next} = Signal.wire ${2:8} in
Signal.assign $1 ${3:data};
$0|snippet}
  ; design "name" "hcname" "Scope-local Signal naming; open Hardcaml; use inside scoped create"
      {snippet|let ( -- ) = Scope.naming ${1:scope} in
let ${2:named} = ${3:signal} -- "$2" in
$0|snippet}
  ; design "hierarchy" "hchier" "Scoped hierarchy wrapper; open Hardcaml, existing I/O/create; explicit module name; scope controls flattening"
      {snippet|let hierarchical scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~name:"${1:register}" ~scope create i
;;
$0|snippet}
  ; design "rtl" "hcrtl" "Print Verilog/VHDL including hierarchy; open Hardcaml, existing I/O/create; stdout, not file output"
      {snippet|let () =
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (I) (O) in
  let circuit = C.create_exn ~name:"${1:top}" (create scope) in
  Rtl.print ~database:(Scope.circuit_database scope) ${2|Verilog,Vhdl|} circuit
;;
$0|snippet}
  ; design "always-variable" "hcavar" "Always DSL alternative register variable; open Hardcaml; spec supplies reset/clear, read .value"
      {snippet|let ${1:state} = Always.Variable.reg ${2:spec} ~width:${3:8} in
$0|snippet}
  ; design "always-wire" "hcawire" "Always DSL alternative combinational variable; open Hardcaml; explicit default prevents latch-like omission"
      {snippet|let ${1:next} = Always.Variable.wire ~default:(Signal.zero ${2:8}) () in
$0|snippet}
  ; design "always-if" "hcaif" "Always DSL conditional list fragment; open Hardcaml, insert inside Always.compile; one-bit condition"
      {snippet|Always.(if_ ${1:condition}
  [ ${2:state} <-- ${3:when_true} ]
  [ $2 <-- ${4:when_false} ]);$0|snippet}
  ; design "always-switch" "hcaswitch" "Always DSL switch list fragment; open Hardcaml; unmatched cases keep variable default/previous register value"
      {snippet|Always.(switch ${1:selector}
  [ Signal.of_int_trunc ~width:${2:2} ${3:0}, [ ${4:state} <-- ${5:data} ]
  ]);$0|snippet}
  ; design "always-sequential" "hcaseq" "Always DSL alternative enabled register; open Hardcaml; compile assignments, then read Signal value"
      {snippet|let ${1:q} = Always.Variable.reg ${2:spec} ~width:${3:8} in
Always.(compile [ when_ ${4:i.enable} [ $1 <-- ${5:i.d} ] ]);
let $1 = $1.value in
$0|snippet}
  ; verification "simulator" "hcsim" "Cyclesim with typed interfaces; open Hardcaml; existing I/O/create; flattened Signal design"
      {snippet|let module Sim = Cyclesim.With_interface (I) (O) in
let scope = Scope.create ~flatten_design:true () in
let ${1:sim} = Sim.create (create scope) in
$0|snippet}
  ; verification "handles" "hchandles" "Cyclesim typed port refs; open Hardcaml; outputs explicitly observed after clock edge"
      {snippet|let ${1:inputs} = Cyclesim.inputs ${2:sim} in
let ${3:outputs} = Cyclesim.outputs ~clock_edge:After $2 in
$0|snippet}
  ; verification "stimulus" "hcdrive" "Drive Cyclesim input ref using current port width; open Hardcaml; integer truncates, cycle before observing"
      {snippet|${1:inputs.d} := Bits.of_int_trunc ~width:(Bits.width !($1)) ${2:42};
$0|snippet}
  ; verification "cycle" "hcstep" "Cyclesim full steps: check, combinational, clock, combinational; open Hardcaml"
      {snippet|Cyclesim.cycle ~n:${1:1} ${2:sim};
$0|snippet}
  ; verification "reset" "hcreset" "Reset Cyclesim internal state; open Hardcaml; not a synchronous DUT clear pulse"
      {snippet|Cyclesim.reset ${1:sim};
$0|snippet}
  ; verification "clear-pulse" "hcclear" "Synchronous active-high clear pulse; open Hardcaml; advances one clear cycle then one released cycle"
      {snippet|${1:inputs.clear} := Bits.vdd;
Cyclesim.cycle ${2:sim};
$1 := Bits.gnd;
Cyclesim.cycle $2;
$0|snippet}
  ; verification "check" "hccheck" "Check current output ref as bit string; open Hardcaml; assert raises on mismatch; no test PPX required"
      {snippet|assert (Bits.equal !(${1:outputs.q}) (Bits.of_string "${2:00101010}"));
$0|snippet}
  ; verification "before-edge" "hcbefore" "Cyclesim pre-edge observation fragment; open Hardcaml; no clock advance until explicit at/after calls"
      {snippet|Cyclesim.cycle_check ${1:sim};
Cyclesim.cycle_before_clock_edge $1;
let ${2:before} = Cyclesim.outputs ~clock_edge:Before $1 in
${3:assert (Bits.equal !(before.q) (Bits.zero 8))};
Cyclesim.cycle_at_clock_edge $1;
Cyclesim.cycle_after_clock_edge $1;
$0|snippet}
  ; verification "expect" "hcexpect" "Signal design expect-test scaffold; hardcaml, ppx_expect, inline_tests; existing I/O/create with clock/clear/d/q"
      {snippet|let%expect_test "${1:register captures input}" =
  let open Hardcaml in
  let module Sim = Cyclesim.With_interface (I) (O) in
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (create scope) in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs ~clock_edge:After sim in
  Cyclesim.reset sim;
  inputs.clear := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.clear := Bits.gnd;
  inputs.d := Bits.of_int_trunc ~width:(Bits.width !(inputs.d)) ${2:42};
  Cyclesim.cycle sim;
  Stdlib.print_endline (Bits.to_string !(outputs.q));
  [%expect {|${3:00101010}|}]
;;
$0|snippet}
  ; verification "wave-capture" "hcwave" "Capture waveform; open Hardcaml; use returned wrapped sim for every subsequent cycle; no waveterm dependency"
      {snippet|let ${1:waves}, ${2:sim} = Cyclesim.Waveform.create $2 in
$0|snippet}
  ; verification "wave-print" "hcwaveprint" "Print captured waveform after stimulus; requires hardcaml_waveterm (v0.18 preview API)"
      {snippet|Hardcaml_waveterm.Waveform.print ~display_width:${1:100} ${2:waves};
$0|snippet}
  ]
;;
