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
type t =
  { language : Language.t
  ; configuration : string
  ; mutable state : state
  ; mutable fail_next_parse : bool
  ; mutable parse_count : int
  }
type result = { snapshot : Snapshot.t; status : Status.t }

let configuration = "tree-sitter.0.1.0/ches-ocaml-structural-v1"

let initialize language query_source =
  match language, query_source with
  | Language.Plain, _ -> Unavailable Unsupported_language
  | _, None -> Unavailable (Initialization "missing compiled highlight query")
  | (Ocaml | Ocaml_interface), Some source ->
    (try
       let grammar =
         match language with
         | Ocaml -> Tree_sitter_ocaml.ocaml ()
         | Ocaml_interface -> Tree_sitter_ocaml.interface ()
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
  { language; configuration; state = initialize language (Queries.source language)
  ; fail_next_parse = false; parse_count = 0
  }
;;
let key t ~document ~revision =
  Snapshot.Key.create ~document ~revision ~language:t.language ~configuration:t.configuration
;;
let close t = t.state <- Unavailable Closed
let parse_count t = t.parse_count

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

let highlight t ~key ~source =
  let plain failure =
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
         Tree_sitter.Parser.reset parser;
         t.parse_count <- t.parse_count + 1;
         let tree = Tree_sitter.Parser.parse_string parser source in
         let root = Tree_sitter.Tree.root_node tree in
         let syntax_errors = Tree_sitter.Node.has_error root in
         let ranges = capture_ranges query root in
         let snapshot = Snapshot.create ~key ~source ranges in
         { snapshot; status = Highlighted { syntax_errors } }
       with
       | Stdlib.Failure message | Invalid_argument message ->
         let failure = Failure.Parsing message in
         t.state <- Unavailable failure;
         plain failure)
;;

module For_testing = struct
  let create_with_query ~language ~query_source =
    { language; configuration = "test-query"; state = initialize language query_source
    ; fail_next_parse = false; parse_count = 0
    }
  ;;
  let fail_next_parse t = t.fail_next_parse <- true
  let supported_length = supported_length
end
