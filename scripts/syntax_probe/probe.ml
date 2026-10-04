(* Phase 0 feasibility probe, not an editor provider or production query. *)
open Tree_sitter

let check condition message = if not condition then failwith message

let captures query tree =
  highlight query tree |> List.sort Stdlib.compare
;;

let has_capture source ranges expected =
  List.exists
    (fun (start, stop, name) ->
      start >= 0
      && stop <= String.length source
      && start < stop
      && (name, String.sub source start (stop - start)) = expected)
    ranges
;;

let query_source keyword function_pattern =
  Printf.sprintf
    {|(comment) @comment
      (string) @string
      (escape_sequence) @escape
      (number) @number
      (value_name) @variable
      (type_constructor) @type
      "%s" @keyword
      %s|}
    keyword
    function_pattern
;;

let probe_language name language source keyword function_pattern expected =
  let parser = Parser.create language in
  let query = Query.create language ~source:(query_source keyword function_pattern) in
  let tree = Parser.parse_string parser source in
  let root = Tree.root_node tree in
  check (not (Node.has_error root)) (name ^ ": valid sample has parse errors");
  check (Node.end_byte root = String.length source) (name ^ ": wrong root byte end");
  let ranges = captures query tree in
  List.iter
    (fun capture ->
      check (has_capture source ranges capture) (name ^ ": missing " ^ fst capture))
    expected;
  check
    (List.mem (0, String.length keyword, "keyword") ranges)
    (name ^ ": wrong keyword range");
  let empty = Parser.parse_string parser "" in
  check (captures query empty = []) (name ^ ": nonempty captures for empty text");
  let incomplete = Parser.parse_string parser (keyword ^ " f :") in
  check (Node.has_error (Tree.root_node incomplete)) (name ^ ": expected error tree");
  ignore (captures query incomplete);
  let invalid_query_rejected =
    try
      ignore (Query.create language ~source:"(not_a_real_node) @bad");
      false
    with
    | Failure _ -> true
  in
  check invalid_query_rejected (name ^ ": invalid query did not raise Failure");
  Printf.printf "ok: %s ABI %d, parse/query, empty/incomplete text, invalid query\n%!"
    name (Language.version language);
  parser, query, tree
;;

let retained_node parser =
  Tree.root_node (Parser.parse_string parser "let x = 1\n")
;;

let rss_kib () =
  let channel = open_in "/proc/self/status" in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    let rec loop () =
      let line = input_line channel in
      if String.starts_with ~prefix:"VmRSS:" line
      then Scanf.sscanf line "VmRSS: %d kB" Fun.id
      else loop ()
    in
    loop ())
;;

let () =
  let source = "let f x = \"é\" (* outer (* inner *) *)\n" in
  let parser, query, tree =
    probe_language
      ".ml"
      (Tree_sitter_ocaml.ocaml ())
      source
      "let"
      "(let_binding pattern: (value_name) @function (parameter))"
      [ "keyword", "let"; "string", "\"é\""; "comment", "(* outer (* inner *) *)"
      ; "function", "f" ]
  in
  check (List.mem (10, 14, "string") (captures query tree)) "UTF-8 byte range";
  let eof = Node.end_point (Tree.root_node tree) in
  check (eof.row = 1 && eof.column = 0) "LF EOF point";
  let unicode_tree = Parser.parse_string parser "let s = \"é\"" in
  let eof = Node.end_point (Tree.root_node unicode_tree) in
  check (eof.row = 0 && eof.column = 12) "point column must count bytes";
  ignore
    (probe_language
       ".mli"
       (Tree_sitter_ocaml.interface ())
       "val f : int -> string\n"
       "val"
       "(value_specification (value_name) @function)"
       [ "keyword", "val"; "function", "f"; "type", "int"; "type", "string" ]);
  let extra_source = "let n = 42\nlet s = \"a\\n\"\n" in
  let extra_tree = Parser.parse_string parser extra_source in
  let ranges = captures query extra_tree in
  List.iter
    (fun capture -> check (has_capture extra_source ranges capture) "number/escape capture")
    [ "number", "42"; "escape", "\\n" ];
  let node = retained_node parser in
  Gc.full_major ();
  Gc.compact ();
  check (Node.end_byte node = 10) "node did not retain tree across GC";
  let cursor = Query_cursor.create () in
  Query_cursor.exec cursor query (retained_node parser);
  Gc.full_major ();
  check (Option.is_some (Query_cursor.next_match cursor)) "query cursor lost its tree";
  (* Keep the query alive as well: the cursor does not own it. *)
  check (Query.capture_count query > 0) "query captures";
  let original = Parser.parse_string parser "let x = 1\n" in
  let edited = Tree.copy original in
  Tree.edit edited
    ~start_byte:8 ~old_end_byte:9 ~new_end_byte:10
    ~start_point:{ row = 0; column = 8 }
    ~old_end_point:{ row = 0; column = 9 }
    ~new_end_point:{ row = 0; column = 10 };
  let incremental = Parser.parse_string ~old:edited parser "let x = 22\n" in
  let fresh = Parser.parse_string parser "let x = 22\n" in
  check (Node.end_byte (Tree.root_node original) = 10) "copy edited original";
  check
    (has_capture "let x = 1\n" (captures query original) ("number", "1"))
    "copy changed original captures";
  check (Tree.root_sexp incremental = Tree.root_sexp fresh) "incremental tree mismatch";
  check (captures query incremental = captures query fresh) "incremental captures mismatch";
  Printf.printf "ok: UTF-8 byte/point coordinates, number/escape, GC ownership, copy/edit/reparse\n%!";
  let large = String.concat "" (List.init 500 (fun _ -> source)) in
  let sample () =
    Gc.full_major ();
    Gc.compact ();
    Printf.printf "RSS after forced GC: %d KiB\n%!" (rss_kib ())
  in
  sample ();
  for _batch = 1 to 4 do
    for _parse = 1 to 200 do
      let parser = Parser.create (Tree_sitter_ocaml.ocaml ()) in
      let query = Query.create (Tree_sitter_ocaml.ocaml ()) ~source:"(comment) @comment" in
      let tree = Parser.parse_string parser large in
      check (List.length (highlight query tree) = 500) "stress capture count"
    done;
    sample ()
  done;
  Printf.printf "ok: 800 fresh parser/query/tree cycles on %d-byte source\n%!" (String.length large)
;;
