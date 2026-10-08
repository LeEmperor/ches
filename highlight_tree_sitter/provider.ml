open! Core
open Ches_highlight

module Failure = struct
  type t =
    | Unsupported_language
    | Initialization of string
    | Parsing of string
    | Closed
    | Key_mismatch
    | Invalid_utf8
    | Source_too_large
  [@@deriving sexp_of, equal]
end

module Status = struct
  type t = Highlighted of { syntax_errors : bool } | Plain of Failure.t
  [@@deriving sexp_of, equal]
end

type handles = { parser : Tree_sitter.Parser.t; query : Tree_sitter.Query.t }
type state = Ready of handles | Unavailable of Failure.t
type retained = { key : Snapshot.Key.t; source : string; tree : Tree_sitter.Tree.t }
type timings = { preparation : float; parsing : float; querying : float; normalization : float }
type t =
  { language : Language.t
  ; configuration : string
  ; mutable state : state
  ; mutable fail_next_parse : bool
  ; mutable parse_count : int
  ; mutable retained : retained option
  ; mutable incremental_count : int
  ; mutable timings : timings option
  }
type result = { snapshot : Snapshot.t; status : Status.t }

let configuration = "tree-sitter.0.1.0/ches-ocaml-structural-v1"

let configuration_for_language = function
  | Language.Systemverilog -> "tree-sitter-systemverilog.d6be6119/ches-sv-structural-v1"
  | Gas -> "tree-sitter-gas.60f44364/ches-gas-grammar-v2/ches-gas-structural-v1"
  | Plain | Ocaml | Ocaml_interface -> configuration
;;

let query_source = function
  | Language.Systemverilog -> Some Systemverilog_queries.source
  | Gas -> Some Gas_queries.source
  | language -> Ocaml_queries.source language
;;

let initialize language query_source =
  match language, query_source with
  | Language.Plain, _ -> Unavailable Unsupported_language
  | _, None -> Unavailable (Initialization "missing compiled highlight query")
  | (Ocaml | Ocaml_interface | Systemverilog | Gas), Some source ->
    (try
       let grammar =
         match language with
         | Ocaml -> Tree_sitter_ocaml.ocaml ()
         | Ocaml_interface -> Tree_sitter_ocaml.interface ()
          | Systemverilog -> Ches_tree_sitter_systemverilog.language ()
          | Gas -> Ches_tree_sitter_gas.language ()
         | Plain -> assert false
       in
       let query = Tree_sitter.Query.create grammar ~source in
       (* The binding does not evaluate predicates. Reject any, including directives,
          rather than silently accepting a query whose meaning we cannot execute. *)
       for pattern = 0 to Tree_sitter.Query.pattern_count query - 1 do
         if not (Array.is_empty (Tree_sitter.Query.predicates_for_pattern query pattern))
         then failwith "highlight query predicates are unsupported"
       done;
       Ready { parser = Tree_sitter.Parser.create grammar; query }
     with
     | Stdlib.Failure message | Invalid_argument message ->
       Unavailable (Initialization message))
;;

let create ~language =
  { language; configuration = configuration_for_language language
   ; state = initialize language (query_source language)
   ; fail_next_parse = false; parse_count = 0; retained = None
   ; incremental_count = 0; timings = None
  }
;;
let key t ~document ~revision =
  Snapshot.Key.create ~document ~revision ~language:t.language ~configuration:t.configuration
;;
let close t = t.state <- Unavailable Closed; t.retained <- None; t.timings <- None
let parse_count t = t.parse_count
let incremental_count t = t.incremental_count
let last_timings t = t.timings

let supported_length length =
  length >= 0 && Int64.(of_int length <= 0xffff_ffffL)
;;

let capture_ranges query root =
  let cursor = Tree_sitter.Query_cursor.create () in
  Tree_sitter.Query_cursor.exec cursor query root;
  let rec loop acc =
    (* Passing query on every cursor call keeps it reachable for the entire scan.
       The binding cursor retains the tree but does not retain the query. *)
    match Tree_sitter.Query_cursor.next_capture cursor query with
    | None -> List.rev acc
    | Some capture ->
      let category =
        Option.bind (Tree_sitter.Query.capture_name_for_id query capture.capture_index)
          ~f:Category.of_capture
      in
      let acc =
        match category with
        | None -> acc
        | Some category ->
          { Snapshot.Range.start = Tree_sitter.Node.start_byte capture.node
          ; stop = Tree_sitter.Node.end_byte capture.node
          ; category
          } :: acc
      in
      loop acc
  in
  loop []
;;

let highlight_impl ~incremental t ~key ~source =
  t.timings <- None;
  let plain failure =
    t.retained <- None;
    (* Empty spans need no source validation. This also safely handles invalid
       UTF-8/oversized input before it ever crosses the C boundary. *)
    { snapshot = Snapshot.create ~key ~source:"" []; status = Plain failure }
  in
  if not (Language.equal t.language (Snapshot.Key.language key))
     || not (String.equal t.configuration (Snapshot.Key.configuration key))
  then plain Key_mismatch
  else if not (supported_length (String.length source)) then plain Source_too_large
  else if not (Stdlib.String.is_valid_utf_8 source) then plain Invalid_utf8
  else
    match t.state with
    | Unavailable failure -> plain failure
    | Ready { parser; query } ->
      (try
         if t.fail_next_parse then (
           t.fail_next_parse <- false;
           failwith "injected parser failure");
          let started = Stdlib.Sys.time () in
          let old =
            if not incremental then None
            else Option.bind t.retained ~f:(fun previous ->
              if not (Snapshot.Key.same_document previous.key key) then None
              else (
                (* Copy before edit: even our private prior tree remains untouched.
                   Immutable snapshots contain no native trees. *)
                let tree = Tree_sitter.Tree.copy previous.tree in
                Option.iter (Edit.between ~old_source:previous.source ~new_source:source)
                  ~f:(fun edit ->
                    let point (p : Edit.point) : Tree_sitter.point =
                      { row = p.row; column = p.column }
                    in
                    Tree_sitter.Tree.edit tree
                      ~start_byte:edit.start_byte ~old_end_byte:edit.old_end_byte
                      ~new_end_byte:edit.new_end_byte ~start_point:(point edit.start_point)
                      ~old_end_point:(point edit.old_end_point)
                      ~new_end_point:(point edit.new_end_point));
                Some tree))
          in
          let prepared = Stdlib.Sys.time () in
          if Option.is_none old then Tree_sitter.Parser.reset parser;
          t.parse_count <- t.parse_count + 1;
          if Option.is_some old then t.incremental_count <- t.incremental_count + 1;
          let tree = Tree_sitter.Parser.parse_string ?old parser source in
          let parsed = Stdlib.Sys.time () in
         let root = Tree_sitter.Tree.root_node tree in
         let syntax_errors = Tree_sitter.Node.has_error root in
          let ranges = capture_ranges query root in
          let queried = Stdlib.Sys.time () in
          let snapshot = Snapshot.create ~key ~source ranges in
          let normalized = Stdlib.Sys.time () in
          t.retained <- (if incremental then Some { key; source; tree } else None);
          t.timings <- Some { preparation = prepared -. started; parsing = parsed -. prepared
                           ; querying = queried -. parsed; normalization = normalized -. queried };
         { snapshot; status = Highlighted { syntax_errors } }
       with
       | Stdlib.Failure message | Invalid_argument message ->
         let failure = Failure.Parsing message in
         t.state <- Unavailable failure;
         plain failure)
;;

let highlight = highlight_impl ~incremental:false
let highlight_incremental = highlight_impl ~incremental:true

module For_testing = struct
  let create_with_query ~language ~query_source =
    { language; configuration = "test-query"; state = initialize language query_source
     ; fail_next_parse = false; parse_count = 0; retained = None
     ; incremental_count = 0; timings = None
    }
  ;;
  let fail_next_parse t = t.fail_next_parse <- true
  let supported_length = supported_length
end
