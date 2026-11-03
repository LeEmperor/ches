open! Core
open Ches_core
open Ches_completion
module U = User_snippets
module M = Model
module B = Text_buffer

let text value = B.of_string value |> Result.ok |> Option.value_exn
let config entries = "{\"version\":1,\"snippets\":[" ^ entries ^ "]}"
let parse entries = U.parse (config entries) |> Or_error.ok_exn
let candidates ?path ?(limit = 100) catalog value =
  U.candidates catalog ~path ~text:(text value) ~cursor:(String.length value) ~limit
;;
let ids entries = List.map entries ~f:(fun entry -> entry.M.Candidate.id)
let has entries id = List.mem (ids entries) ("user-snippet:" ^ id) ~equal:String.equal

let%test_unit "catalog variables resolve per request before indentation and choice edits stay linked" =
  let catalog = parse
      {json|{"id":"context","prefix":"ctx","body":"$TM_FILENAME/$TM_FILENAME_BASE/$TM_DIRECTORY/${TM_FILEPATH:unnamed}\n$1/${1|é\nx,long\ny|}$0!"}|json} in
  let c = candidates ~path:"../rtl/top.test.sv" catalog "  ctx" |> List.hd_exn in
  [%test_eq: string] c.primary.text
    "top.test.sv/top.test/../rtl/../rtl/top.test.sv\n  é\n  x/é\n  x!";
  let installed = Text_edit.apply (text "  ctx") [[c.primary]] |> Or_error.ok_exn in
  let module S = Snippet.Session in
  let template = Option.value_exn c.snippet in
  let session = S.start template ~base:2 ~revision:1 ~text:installed |> Or_error.ok_exn in
  [%test_eq: string list option] (S.choices session) (Some ["é\n  x"; "long\n  y"]);
  let change = S.cycle_choice session Next ~revision:1 ~text:installed |> Or_error.ok_exn in
  let edited = Text_edit.apply installed [S.edits change] |> Or_error.ok_exn in
  [%test_eq: string] (B.to_string edited)
    "  top.test.sv/top.test/../rtl/../rtl/top.test.sv\n  long\n  y/long\n  y!";
  let session = S.applied change ~revision:2 in
  assert (Option.is_some (S.selection session));
  let change = S.insert session ~revision:2 ~text:edited "custom" |> Or_error.ok_exn in
  let edited = Text_edit.apply edited [S.edits change] |> Or_error.ok_exn in
  assert (String.is_suffix (B.to_string edited) ~suffix:"\n  custom/custom!");
  let unnamed = candidates catalog "ctx" |> List.hd_exn in
  assert (String.is_prefix unnamed.primary.text ~prefix:"///unnamed\n");
  let other = candidates ~path:"second.ml" catalog "ctx" |> List.hd_exn in
  assert (String.is_prefix other.primary.text ~prefix:"second.ml/second/./second.ml\n")
;;

let%test_unit "bundled SV starters parse, scope, labels and candidate contract" =
  List.iter [ "x.sv"; "x.svh" ] ~f:(fun path ->
    let all = candidates ~path U.builtins "" in
    assert (List.length all = 5);
    List.iter [ "aff"; "acomb"; "mod"; "inst"; "genfor" ] ~f:(fun prefix ->
      let c = candidates ~path U.builtins prefix |> List.hd_exn in
      assert (String.equal c.label prefix);
      assert (String.equal c.id ("user-snippet:sv." ^ prefix));
      assert (M.Candidate.equal_source c.source Snippet);
      assert (Option.is_some c.detail);
      assert (List.is_empty c.additional);
      assert (c.primary.start = 0 && c.primary.stop = String.length prefix);
      let snippet = Option.value_exn c.snippet in
      assert (String.equal c.primary.text (Snippet.text snippet));
      assert (c.cursor = Snippet.final_cursor snippet)));
  List.iter [ "x.v"; "x.vh"; "x.ml"; "x.SV" ] ~f:(fun path ->
    assert (List.is_empty (candidates ~path U.builtins "")));
  assert (List.is_empty (candidates U.builtins ""))
;;

let%test_unit "omitted and empty global scopes, language scopes and custom extensions" =
  let catalog = parse {|{"id":"global","prefix":"q","body":"g"},
    {"id":"empty","prefix":"q","scope":[],"body":["a","b"]},
    {"id":"v","prefix":"q","scope":["verilog"],"body":"v"},
    {"id":"ml","prefix":"q","scope":["ocaml"],"body":"ml"},
    {"id":"custom","prefix":"q","scope":[".foo"],"body":"foo"}|} in
  let globals = candidates catalog "q" in
  assert (List.length globals = 2 && has globals "global" && has globals "empty");
  List.iter [ "a.v"; "a.vh" ] ~f:(fun path ->
    assert (has (candidates ~path catalog "q") "v"));
  List.iter [ "a.ml"; "a.mli" ] ~f:(fun path ->
    assert (has (candidates ~path catalog "q") "ml"));
  assert (has (candidates ~path:"dir/a.foo" catalog "q") "custom");
  assert (not (has (candidates ~path:"a.foobar" catalog "q") "custom"));
  assert (List.is_empty (candidates ~path:"a.foo" catalog "Q"))
;;

let%test_unit "user replacement and disabling are applied to fresh bundled catalog" =
  let catalog = parse {|{"id":"sv.aff","prefix":"mine","body":"${1:custom}"},
    {"id":"sv.acomb","disabled":true},{"id":"unknown","disabled":true}|} in
  assert (List.is_empty (candidates ~path:"a.sv" catalog "aff"));
  assert (has (candidates catalog "mine") "sv.aff");
  assert (not (has (candidates ~path:"a.sv" catalog "") "sv.acomb"));
  assert (has (candidates ~path:"a.sv" (parse "") "aff") "sv.aff");
  assert (has (candidates ~path:"a.sv" U.builtins "acomb") "sv.acomb")
;;

let error_contains input fragments =
  match U.parse input with
  | Ok _ -> failwith "expected invalid config"
  | Error error ->
    let message = Error.to_string_hum error in
    List.iter fragments ~f:(fun substring -> assert (String.is_substring message ~substring))
;;

let%test_unit "strict malformed configs identify entry and id without changing old catalog" =
  List.iter
    [ {|{"id":"oops","body":"x"}|}, "prefix"
    ; {|{"id":"oops","prefix":"x","body":2}|}, "body"
    ; {|{"id":"oops","prefix":"x","body":["x",2]}|}, "body line"
    ; {|{"id":"oops","prefix":"x","scope":"ocaml","body":"x"}|}, "scope"
    ; {|{"id":"oops","prefix":"x","scope":["python"],"body":"x"}|}, ".filename-extension"
    ; {|{"id":"oops","prefix":"x","scope":["."],"body":"x"}|}, "unsupported scope"
    ; {|{"id":"oops","prefix":"x","body":"${VARIABLE}"}|}, "body"
    ; {json|{"id":"oops","prefix":"x","body":"${1|a,b}"}|json}, "body"
    ; {json|{"id":"oops","prefix":"x","body":"${TM_FILENAME:unterminated"}|json}, "body"
    ; {json|{"id":"oops","prefix":"x","body":"${TM_FILENAME:$0}"}|json}, "body"
    ; {|{"id":"oops","prefix":"x","body":"x","typo":true}|}, "unknown field"
    ; {|{"id":"oops","disabled":"true"}|}, "disabled"
    ; {|{"id":"oops","disabled":true,"prefix":"x"}|}, "unknown field"
    ; {|{"id":"oops","id":"again","disabled":true}|}, "duplicate field"
    ]
    ~f:(fun (entry, reason) ->
      error_contains (config entry) [ "snippets[0]"; reason ]);
  error_contains (config {|{"id":"same","disabled":true},{"id":"same","disabled":true}|})
    [ "snippets[1]"; "same"; "duplicate user id" ];
  List.iter [ "{}"; {|{"version":2,"snippets":[]}|};
              {|{"version":1,"snippets":{}}|};
              {|{"version":1,"snippets":[],"extra":0}|}; "not json" ]
    ~f:(fun input -> error_contains input []);
  assert (List.length (candidates ~path:"a.sv" U.builtins "") = 5)
;;

let%test_unit "file, entry and body limits" =
  error_contains (String.make 1_048_577 ' ') [ "1 MiB" ];
  let entries = List.init 1001 ~f:(fun n ->
    "{\"id\":\"" ^ Int.to_string n ^ "\",\"disabled\":true}") in
  error_contains (config (String.concat ~sep:"," entries)) [ "1000" ];
  assert (Result.is_ok (U.parse (config (String.concat ~sep:"," (List.take entries 1000)))));
  error_contains
    (config ("{\"id\":\"large\",\"prefix\":\"x\",\"body\":\"" ^ String.make 65_537 'a' ^ "\"}"))
    [ "snippets[0]"; "large"; "65536" ]
;;

let%test_unit "indentation covers multiline mirrors and reparsed ranges support linked editing" =
  let catalog = parse {|{"id":"multi","prefix":"xx","body":"$1\n  ${1:a\n b}\n$0"}|} in
  let base = text "prior\n\t  xxTAIL" in
  let c = U.candidates catalog ~path:None ~text:base ~cursor:11 ~limit:10 |> List.hd_exn in
  assert (c.primary.start = 9 && c.primary.stop = 11);
  assert (String.equal c.primary.text "a\n\t   b\n\t    a\n\t   b\n\t  ");
  let snippet = Option.value_exn c.snippet in
  let fields = Snippet.fields snippet in
  let ranges = (List.hd_exn fields).ranges in
  assert (List.length ranges = 2);
  List.iter ranges ~f:(fun range ->
    assert (String.equal (String.sub c.primary.text ~pos:range.start ~len:(range.stop - range.start))
              "a\n\t   b"));
  let installed = Text_edit.apply base [[ c.primary ]] |> Or_error.ok_exn in
  let session = Snippet.Session.start snippet ~base:9 ~revision:1 ~text:installed |> Or_error.ok_exn in
  let change = Snippet.Session.insert session ~revision:1 ~text:installed "value" |> Or_error.ok_exn in
  let edited = Text_edit.apply installed [Snippet.Session.edits change] |> Or_error.ok_exn in
  assert (String.equal (B.to_string edited) "prior\n\t  value\n\t    value\n\t  TAIL");
  let unicode = candidates catalog "  λ; xx" |> List.hd_exn in
  assert (String.is_substring unicode.primary.text ~substring:"\n  ")
;;

let%test_unit "candidate bounds and template ranking preserve distinct semantics" =
  let catalog = parse {|{"id":"one","prefix":"foo","body":"${1:foo}$0"},
    {"id":"two","prefix":"foo","body":"f${1:oo}$0"}|} in
  assert (List.is_empty (candidates ~limit:0 catalog "f"));
  assert (List.is_empty (candidates ~limit:(-1) catalog "f"));
  assert (List.length (candidates ~limit:1 catalog "f") = 1);
  assert (List.is_empty (U.candidates catalog ~path:None ~text:(text "é") ~cursor:1 ~limit:5));
  assert (List.is_empty (candidates catalog (String.make 4097 'f')));
  let base = text "f foo" in
  let token = { M.Token.resource = "test"; generation = 0; revision = 0; request = 1 } in
  let session limit = M.start ~token ~text:base ~cursor:1 ~words:(M.Buffer_words.create base) ~limit ()
    |> Option.value_exn |> fst in
  let templates = U.candidates catalog ~path:None ~text:base ~cursor:1 ~limit:100 in
  let plain = { (List.hd_exn templates) with M.Candidate.id = "plain"; source = Lsp "test"
    ; sort_text = "aaa"; snippet = None } in
  let merge t source candidates = M.receive t { M.Reply.token; source; candidates; incomplete = false } in
  let merged = merge (merge (session 10) "lsp" [plain]) "snippets" templates |> M.candidates in
  assert (List.length merged = 3);
  assert (Option.is_some (List.nth_exn merged 0).snippet);
  assert (Option.is_some (List.nth_exn merged 1).snippet);
  assert (Option.is_none (List.nth_exn merged 2).snippet);
  let limited = merge (merge (session 1) "lsp" [plain]) "snippets" templates |> M.candidates in
  assert (List.length limited = 1 && Option.is_some (List.hd_exn limited).snippet)
;;

let%test_unit "indentation keeps escapes, coincident fields and final cursor before digits" =
  let original = Snippet.parse "$2$1${3:a\\}b}\n$3${0}1\\$\\\\" |> Or_error.ok_exn in
  let indented = Snippet.indent original ~prefix:"  " |> Or_error.ok_exn in
  assert (String.equal (Snippet.text indented) "a}b\n  a}b1$\\");
  assert (Snippet.final_cursor indented = 9);
  assert (List.length (Snippet.fields indented) = 3);
  let too_large = Snippet.parse "a\nb" |> Or_error.ok_exn in
  assert (Result.is_error (Snippet.indent too_large ~prefix:(String.make 65_536 ' ')))
;;

let%test_unit "escaped multiline defaults survive JSON, indentation and linked replacement" =
  let catalog = parse
      {|{"id":"escaped","prefix":"esc","body":"$1\n${1:a\\\\\n\\$\\}b}\n\\\\\n\\$${0}7"}|} in
  let base = text "\t escTAIL" in
  let c = U.candidates catalog ~path:None ~text:base ~cursor:5 ~limit:10 |> List.hd_exn in
  let snippet = Option.value_exn c.snippet in
  let value = "a\\\n\t $}b" in
  assert (String.equal c.primary.text (value ^ "\n\t " ^ value ^ "\n\t \\\n\t $7"));
  let ranges = (List.hd_exn (Snippet.fields snippet)).ranges in
  assert (List.length ranges = 2);
  List.iter ranges ~f:(fun range ->
    assert (String.equal value (String.sub c.primary.text ~pos:range.start
      ~len:(range.stop - range.start))));
  assert (Snippet.final_cursor snippet = String.length c.primary.text - 1);
  let installed = Text_edit.apply base [[c.primary]] |> Or_error.ok_exn in
  let session = Snippet.Session.start snippet ~base:2 ~revision:1 ~text:installed |> Or_error.ok_exn in
  let change = Snippet.Session.insert session ~revision:1 ~text:installed "new" |> Or_error.ok_exn in
  let edited = Text_edit.apply installed [Snippet.Session.edits change] |> Or_error.ok_exn in
  assert (String.equal (B.to_string edited) "\t new\n\t new\n\t \\\n\t $7TAIL")
;;

let%test_unit "builtin template survives same-label LSP word and different LSP template" =
  let base = text "aff" in
  let token = { M.Token.resource = "test.sv"; generation = 0; revision = 0; request = 1 } in
  let model = M.start ~token ~text:base ~cursor:3 ~words:(M.Buffer_words.create base) ~limit:10 ()
      |> Option.value_exn |> fst in
  let builtin = candidates ~path:"test.sv" U.builtins "aff" |> List.hd_exn in
  let template = Snippet.parse "${1:aff}$0" |> Or_error.ok_exn in
  let lsp = { builtin with M.Candidate.id = "lsp-template"; source = Lsp "test"
    ; sort_text = "000"; primary = { start = 0; stop = 3; text = Snippet.text template }
    ; cursor = Snippet.final_cursor template; snippet = Some template } in
  let word = { lsp with id = "lsp-word"; sort_text = ""; snippet = None } in
  let merge model source candidates =
    M.receive model { M.Reply.token; source; candidates; incomplete = false } in
  List.iter [true; false] ~f:(fun builtin_first ->
    let merged = if builtin_first then
        merge (merge model "\000user-snippets" [builtin]) "test" [word; lsp]
      else merge (merge model "test" [word; lsp]) "\000user-snippets" [builtin] in
    let all = M.candidates merged in
    assert (List.length all = 3);
    assert (List.exists all ~f:(fun c -> M.Candidate.equal c builtin));
    assert (List.for_all all ~f:(fun c -> String.equal c.label "aff"));
    assert (Option.is_some (List.nth_exn all 0).snippet);
    assert (Option.is_some (List.nth_exn all 1).snippet);
    assert (Option.is_none (List.nth_exn all 2).snippet))
;;
