open! Core
open Ches_highlight
open Ches_highlight_tree_sitter

let make_key provider ?(revision = 0) () =
  Provider.key provider ~document:(Snapshot.Document_id.create ()) ~revision
;;
let run provider source =
  let key = make_key provider () in
  let result = Provider.highlight provider ~key ~source in
  assert (Snapshot.matches result.snapshot key);
  result
;;
let successful ?(syntax_errors = false) (result : Provider.result) =
  if not (Provider.Status.equal result.status (Highlighted { syntax_errors }))
  then raise_s [%sexp "unexpected provider status", (result.status : Provider.Status.t)]
;;
let slices source (result : Provider.result) =
  List.map (Snapshot.ranges result.snapshot) ~f:(fun range ->
    String.sub source ~pos:range.start ~len:(range.stop - range.start), range.category)
;;
let check_slice source result token category =
  let found = slices source result in
  if not (List.exists found ~f:(fun (text, cat) -> String.equal text token && Category.equal cat category))
  then raise_s [%sexp "missing highlight", (token : string), (category : Category.t),
    (found : (string * Category.t) list)]
;;

let%test_unit "both compiled-in queries initialize and highlight empty input" =
  List.iter [ Language.Ocaml; Ocaml_interface ] ~f:(fun language ->
    let provider = Provider.create ~language in
    let result = run provider "" in
    successful result;
    [%test_result: Snapshot.Range.t list] (Snapshot.ranges result.snapshot) ~expect:[];
    Provider.close provider)
;;

let%test_unit "implementation baseline categories and structural function recognition" =
  let source =
    "type item = Leaf of int | Node of item list\n\
     type record = { count : int }\n\
     module M = struct let f x = x + 42 end\n\
     let apply x = M.f x\n\
     let lambda = fun x -> x\n\
     let cases = function Leaf n -> n | Node _ -> 0\n\
     let s = \"é\\n\"\n\
     let yes = true\n\
     let r = { count = 1 }\n"
  in
  let provider = Provider.create ~language:Ocaml in
  let result = run provider source in
  successful result;
  List.iter
    [ "type", Category.Keyword; "item", Type; "Leaf", Constructor; "M", Module
    ; "f", Function; "apply", Function; "lambda", Function; "cases", Function
    ; "x", Variable; "count", Property; "42", Number; "true", Constant
    ; "+", Operator; "=", Operator; "{", Punctuation; "}", Punctuation
    ; "\"é", String; "\\n", Escape; "\"", String
    ] ~f:(fun (token, category) -> check_slice source result token category);
  Provider.close provider
;;

let%test_unit "interface types, modules, functions, constants and external string escapes" =
  let source =
    "type 'a t = Ready of 'a\n\
     module type S = sig val f : int -> string val version : int end\n\
     module M : S\n\
     val identity : 'a -> 'a\n\
     external ffi : int -> int = \"primitive\\n\"\n\
     (* outer\n (* inner let fake = 42 *)\n done *)\n"
  in
  let provider = Provider.create ~language:Ocaml_interface in
  let result = run provider source in
  successful result;
  List.iter
    [ "val", Category.Keyword; "'a", Type; "t", Type; "Ready", Constructor
    ; "S", Module; "M", Module; "f", Function; "identity", Function
    ; "version", Variable; "ffi", Function; "int", Type; "string", Type; "->", Operator
    ; "\"primitive", String; "\\n", Escape
    ; "(* outer\n (* inner let fake = 42 *)\n done *)", Comment
    ] ~f:(fun (token, category) -> check_slice source result token category);
  Provider.close provider
;;

let%test_unit "multiline nested comments and quoted strings do not leak code categories" =
  let comment = "(* let f x = \"hi\"\n (* inner 42 + foo *)\n end *)" in
  let quoted = "{tag|let fake = 42\n(* not a comment *) é|tag}" in
  let source = comment ^ "\nlet s = " ^ quoted ^ "\nlet c = '\\n'\n" in
  let provider = Provider.create ~language:Ocaml in
  let result = run provider source in
  successful result;
  check_slice source result comment Comment;
  check_slice source result quoted String;
  let string_start = String.length comment + String.length "\nlet s = " in
  for offset = 0 to String.length comment - 1 do
    [%test_result: Category.t] (Snapshot.category_at result.snapshot offset) ~expect:Comment
  done;
  for offset = string_start to string_start + String.length quoted - 1 do
    [%test_result: Category.t] (Snapshot.category_at result.snapshot offset) ~expect:String
  done;
  check_slice source result "\\n" Escape;
  let literal = "\"let type x = (42); [a], {b}: foo |> bar %04d @[%s@]\"" in
  let source = "let s = " ^ literal in
  let result = run provider source in
  successful result;
  check_slice source result literal String;
  Provider.close provider
;;

let%test_unit "exact Unicode byte spans, escape specificity and unmatched whitespace" =
  let source = "let s = \"é\\n界\"\n" in
  let provider = Provider.create ~language:Ocaml in
  let result = run provider source in
  successful result;
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges result.snapshot)
    ~expect:
      [ { start = 0; stop = 3; category = Keyword }
      ; { start = 4; stop = 5; category = Variable }
      ; { start = 6; stop = 7; category = Operator }
      ; { start = 8; stop = 11; category = String }
      ; { start = 11; stop = 13; category = Escape }
      ; { start = 13; stop = 17; category = String }
      ];
  [%test_result: Category.t] (Snapshot.category_at result.snapshot 3) ~expect:Plain;
  [%test_result: Category.t] (Snapshot.category_at result.snapshot 17) ~expect:Plain;
  Provider.close provider
;;

let%test_unit "numeric forms, multiline strings, escaped characters and Unicode interface strings" =
  let source =
    "let numbers = [0x2a; 1_000; 3.14e2; 42L; -7]\n\
     let text = \"first\nsecond é\"\n\
     let char = '\\x41'\n"
  in
  let provider = Provider.create ~language:Ocaml in
  let result = run provider source in
  successful result;
  List.iter [ "0x2a"; "1_000"; "3.14e2"; "42L"; "7" ] ~f:(fun token ->
    check_slice source result token Number);
  check_slice source result "-" Operator;
  check_slice source result "\"first\nsecond é\"" String;
  check_slice source result "\\x41" Escape;
  Provider.close provider;
  let provider = Provider.create ~language:Ocaml_interface in
  let source = "external f : int -> int = \"é\\n界\"\n" in
  let result = run provider source in
  successful result;
  check_slice source result "f" Function;
  check_slice source result "\"é" String;
  check_slice source result "\\n" Escape;
  check_slice source result "界\"" String;
  Provider.close provider
;;

let%test_unit "unfinished strings/comments and syntax errors remain ordinary editing states" =
  List.iter [ Language.Ocaml; Ocaml_interface ] ~f:(fun language ->
    let provider = Provider.create ~language in
    let header = match language with Ocaml -> "let x =" | Ocaml_interface -> "val x :" | Plain | Systemverilog -> assert false in
    List.iter [ header ^ " )"; "(* outer\n (* unfinished"; header ^ " \"unfinished" ] ~f:(fun source ->
      let result = run provider source in
      assert (match result.status with Highlighted _ -> true | Plain _ -> false));
    successful (run provider "");
    Provider.close provider)
;;

let%test_unit "incomplete and malformed code retains useful captures and recovers" =
  List.iter
    [ Language.Ocaml, "let good = 42\nlet broken =", "let good = 42\nlet fixed x = x\n"
    ; Ocaml_interface, "val good : int\nval broken :", "val good : int\nval fixed : int -> int\n"
    ] ~f:(fun (language, incomplete, repaired) ->
      let provider = Provider.create ~language in
      let bad = run provider incomplete in
      successful ~syntax_errors:true bad;
      check_slice incomplete bad "good" Variable;
      let good = run provider repaired in
      successful good;
      check_slice repaired good "fixed" Function;
      (* No old tree is retained or passed back: prior snapshots remain unchanged. *)
      let before = Snapshot.ranges good.snapshot in
      ignore (run provider "" : Provider.result);
      [%test_result: Snapshot.Range.t list] (Snapshot.ranges good.snapshot) ~expect:before;
      Provider.close provider)
;;

let assert_plain (result : Provider.result) =
  assert (match result.status with Plain _ -> true | Highlighted _ -> false);
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges result.snapshot) ~expect:[]
;;

let%test_unit "missing, invalid and predicate-bearing queries fail safely" =
  List.iter [ Language.Ocaml; Ocaml_interface ] ~f:(fun language ->
    List.iter [ None; Some "(not_a_real_node) @keyword";
                Some "((value_name) @variable (#eq? @variable \"x\"))" ] ~f:(fun query_source ->
      let provider = Provider.For_testing.create_with_query ~language ~query_source in
      let result = run provider "let x = 1\n" in
      assert_plain result;
      assert (match result.status with Plain (Initialization _) -> true | _ -> false);
      Provider.close provider));
  let provider = Provider.create ~language:Plain in
  let result = run provider "anything" in
  assert_plain result;
  assert (Provider.Status.equal result.status (Plain Unsupported_language))
;;

let%test_unit "unknown and internal provider captures never mask recognized categories" =
  let provider = Provider.For_testing.create_with_query ~language:Ocaml
      ~query_source:(Some "(compilation_unit) @unknown\n(value_name) @variable.parameter\n(value_name) @_internal") in
  let source = "let x = 1" in
  let result = run provider source in
  successful result;
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges result.snapshot)
    ~expect:[ { start = 4; stop = 5; category = Variable } ];
  Provider.close provider
;;

let%test_unit "parse failure discards prior ranges, disables session and accepts explicit recreation" =
  let provider = Provider.create ~language:Ocaml in
  let first = run provider "let x = 1" in
  successful first;
  let saved = Snapshot.ranges first.snapshot in
  Provider.For_testing.fail_next_parse provider;
  let failed = run provider "let y = 2" in
  assert_plain failed;
  assert (match failed.status with Plain (Parsing _) -> true | _ -> false);
  let retry = run provider "let z = 3" in
  assert_plain retry;
  assert (Provider.Status.equal failed.status retry.status);
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges first.snapshot) ~expect:saved;
  Provider.close provider;
  Provider.close provider;
  let closed = run provider "let z = 3" in
  assert_plain closed;
  assert (Provider.Status.equal closed.status (Plain Closed));
  let recreated = Provider.create ~language:Ocaml in
  successful (run recreated "let z = 3");
  Provider.close recreated
;;

let%test_unit "provider rejects wrong language/configuration and invalid UTF-8 before parsing" =
  let provider = Provider.create ~language:Ocaml in
  let document = Snapshot.Document_id.create () in
  List.iter
    [ Language.Ocaml_interface, Provider.configuration; Ocaml, "wrong-query-version" ]
    ~f:(fun (language, configuration) ->
      let key = Snapshot.Key.create ~document ~revision:7 ~language ~configuration in
      let result = Provider.highlight provider ~key ~source:"let x = 1" in
      assert_plain result;
      assert (Snapshot.matches result.snapshot key);
      assert (Provider.Status.equal result.status (Plain Key_mismatch)));
  let invalid = run provider "\255" in
  assert_plain invalid;
  assert (Provider.Status.equal invalid.status (Plain Invalid_utf8));
  successful (run provider "let x = 1");
  Provider.close provider;
  List.iter [ -1; Int.max_value ] ~f:(fun n -> assert (not (Provider.For_testing.supported_length n)));
  List.iter [ 0; 1; 0xffff_ffff ] ~f:(fun n -> assert (Provider.For_testing.supported_length n));
  assert (not (Provider.For_testing.supported_length 0x1_0000_0000))
;;

let%test_unit "reused sessions equal fresh providers across unrelated documents and forced GC" =
  List.iter [ Language.Ocaml; Ocaml_interface ] ~f:(fun language ->
    let provider = Provider.create ~language in
    let sources =
      match language with
      | Ocaml -> [ "let f x = \"é\\n\"\n"; "(* a\n (* b *) *)\nlet x = 42"; "let x ="; "" ]
      | Ocaml_interface -> [ "val f : int -> string\n"; "(* a\n (* b *) *)\nval x : int"; "val x :"; "" ]
      | Plain | Systemverilog -> assert false
    in
    for i = 0 to 39 do
      let source = List.nth_exn sources (i mod List.length sources) in
      let reused = run provider source in
      let fresh = Provider.create ~language in
      let expected = run fresh source in
      assert (Provider.Status.equal reused.status expected.status);
      [%test_result: Snapshot.Range.t list]
        (Snapshot.ranges reused.snapshot) ~expect:(Snapshot.ranges expected.snapshot);
      Provider.close fresh;
      if i mod 10 = 0 then Gc.full_major ()
    done;
    Provider.close provider)
;;
