open! Core
open Ches_core
module N = Ches_completion.Snippet
module S = N.Session
module B = Text_buffer

let buffer s = B.of_string s |> Result.ok |> Option.value_exn
let parse s = N.parse s |> Or_error.ok_exn
let range start stop : N.range = { start; stop }
let field number ranges : N.field = { number; ranges }
let start ?(prefix = "") ?(suffix = "") input =
  let template = parse input in
  let text = buffer (prefix ^ N.text template ^ suffix) in
  S.start template ~base:(String.length prefix) ~revision:10 ~text |> Or_error.ok_exn, text
;;
let apply change text revision =
  let text = Text_edit.apply text [ S.edits change ] |> Or_error.ok_exn in
  let session = S.applied change ~revision in
  assert (S.matches session ~revision ~text);
  assert (S.cursor session = S.cursor_after change);
  assert (B.is_boundary text (S.cursor session));
  session, text
;;
let insert session text revision value =
  let change = S.insert session ~revision ~text value |> Or_error.ok_exn in
  apply change text (revision + 1)
;;
let active_range session = (S.active session |> Option.value_exn).ranges |> List.hd_exn

let cycle session text revision direction =
  S.cycle_choice session direction ~revision ~text |> Or_error.ok_exn
  |> fun change -> apply change text (revision + 1)
;;

let%test_unit "choice escapes, forward mirrors, custom text and selected cycling" =
  let session, text = start ~prefix:"π:" {snippet|$1/${1|é,a\,b,c\|d,e\\f,|}/${2:x}$0!|snippet} in
  [%test_eq: string list option] (S.choices session) (Some ["é"; "a,b"; "c|d"; "e\\f"; ""]);
  [%test_eq: string] (B.to_string text) "π:é/é/x!";
  let session, text = cycle session text 10 Previous in
  [%test_eq: string] (B.to_string text) "π://x!";
  [%test_eq: N.range option] (S.selection session) (S.active_range session);
  let session, text = insert session text 11 "custom" in
  [%test_eq: string] (B.to_string text) "π:custom/custom/x!";
  let session, text = cycle session text 12 Next in
  [%test_eq: string] (B.to_string text) "π:é/é/x!";
  let session, text = insert session text 13 "other" in
  let session, text = cycle session text 14 Previous in
  [%test_eq: string] (B.to_string text) "π://x!";
  let session, text = cycle session text 15 Next in
  let second = (S.active session |> Option.value_exn).ranges |> List.last_exn in
  let session = S.set_cursor session second.start |> Or_error.ok_exn in
  let session, text = cycle session text 16 Next in
  [%test_eq: string] (B.to_string text) "π:a,b/a,b/x!";
  [%test_eq: N.range option] (S.selection session) (S.active_range session);
  assert (S.cursor session = String.length "π:a,b/a,b");
  let other = S.navigate session Next in
  assert (Option.is_none (S.choices other));
  assert (Result.is_error (S.cycle_choice other Next ~revision:17 ~text));
  let back = S.navigate other Previous in
  assert (Option.is_some (S.choices back));
  assert (S.cursor (S.navigate other Next) = B.length text - 1);
  assert (Result.is_error (S.cycle_choice session Next ~revision:16 ~text));
  assert (Result.is_error (S.cycle_choice session Next ~revision:17 ~text:(buffer "different")))
;;

let%test_unit "choice validation, repeated metadata and literal dollar choices" =
  List.iter ["${0|a,b|}"; "${1|a,b|}${1|a,c|}"; "${1:x}${1|a,b|}";
             "${1|a,b"; "${1|a\\x,b|}"; "${1|a\\";
             "${TM_FILENAME/a/b/}"; "${TM_FILENAME:$TM_FILEPATH}";
             "${1:${TM_FILENAME_BASE}}"] ~f:(fun s -> assert (Result.is_error (N.parse s)));
  [%test_eq: string] (N.text (parse "${1|$literal,b|}${1|$literal,b|}")) "$literal$literal";
  let session, text = start "${1||}$1$0" in
  let session, text = cycle session text 10 Next in
  assert (B.length text = 0 && Option.is_some (S.selection session))
;;

let%test_unit "filename variables resolve lexically, retain raw structure and relocate UTF8 fields" =
  let template = parse "$TM_FILENAME|${TM_FILENAME_BASE}|$TM_DIRECTORY|${TM_FILEPATH:missing}|${1:猫}$0!" in
  [%test_eq: string] (N.text template) "|||missing|猫!";
  let resolved = N.resolve template ~path:(Some "../dir/é.test.sv") |> Or_error.ok_exn in
  [%test_eq: string] (N.text resolved) "é.test.sv|é.test|../dir|../dir/é.test.sv|猫!";
  let last = List.hd_exn (N.fields resolved) |> fun (f : N.field) -> List.hd_exn f.ranges in
  assert (last.start = String.length "é.test.sv|é.test|../dir|../dir/é.test.sv|");
  assert (N.final_cursor resolved = last.stop);
  let rerendered = N.resolve resolved ~path:(Some "rtl/top.v") |> Or_error.ok_exn in
  [%test_eq: string] (N.text rerendered) "top.v|top|rtl|rtl/top.v|猫!";
  List.iter [None; Some ""] ~f:(fun path ->
    [%test_eq: string] (N.text (N.resolve resolved ~path |> Or_error.ok_exn)) "|||missing|猫!");
  let defaults = parse {|${TM_FILENAME:a\$b\}c\\d}|} in
  [%test_eq: string] (N.text defaults) "a$b}c\\d";
  let relative = N.resolve template ~path:(Some "top") |> Or_error.ok_exn in
  [%test_eq: string] (N.text relative) "top|top|.|top|猫!";
  (match N.parse "$UNKNOWN" with
   | Ok _ -> assert false
   | Error e -> assert (String.is_substring (Error.to_string_hum e) ~substring:"unsupported snippet variable UNKNOWN"))
;;

let%test_unit "indentation retains multiline choices and variables across resolution and sessions" =
  let raw = parse "$TM_FILENAME\n$1/${1|a\nb,c\nd|}$0!" in
  let indented = N.indent raw ~prefix:"  " |> Or_error.ok_exn in
  let template = N.resolve indented ~path:(Some "rtl/中.sv") |> Or_error.ok_exn in
  [%test_eq: string] (N.text template) "中.sv\n  a\n  b/a\n  b!";
  let text = buffer ("前" ^ N.text template) in
  let session = S.start template ~base:3 ~revision:10 ~text |> Or_error.ok_exn in
  [%test_eq: string list option] (S.choices session) (Some ["a\n  b"; "c\n  d"]);
  let session, text = cycle session text 10 Next in
  [%test_eq: string] (B.to_string text) "前中.sv\n  c\n  d/c\n  d!";
  let session, text = insert session text 11 "short" in
  [%test_eq: string] (B.to_string text) "前中.sv\n  short/short!";
  let session, text = cycle session text 12 Previous in
  [%test_eq: string] (B.to_string text) "前中.sv\n  c\n  d/c\n  d!";
  assert (S.cursor (S.navigate session Next) = B.length text - 1)
;;

let%test_unit "duplicate choices advance and alternate option expansion remains bounded" =
  let session, text = start "${1|a,a,b|}" in
  let session, text = cycle session text 10 Next in
  [%test_eq: string] (B.to_string text) "a";
  let session, text = cycle session text 11 Next in
  [%test_eq: string] (B.to_string text) "b";
  let _, text = cycle session text 12 Next in
  [%test_eq: string] (B.to_string text) "a";
  let session, text = start ("${1|," ^ String.make 512 'x' ^ "|}"
    ^ String.concat (List.init 2200 ~f:(fun _ -> "$1"))) in
  assert (Result.is_error (S.cycle_choice session Next ~revision:10 ~text));
  let many_lines = parse ("${1|x," ^ String.make 100 '\n' ^ "|}") in
  assert (Result.is_error (N.indent many_lines ~prefix:(String.make 20_000 ' ')));
  let variable = parse "$TM_FILEPATH$1$0" in
  assert (Result.is_error (N.resolve variable ~path:(Some (String.make 1_048_577 'x'))));
  assert (Result.is_error (N.resolve variable ~path:(Some "bad\255")))
;;

let%test_unit "resolution and indentation commute while installed ranges stay frozen" =
  let raw = parse "${TM_FILEPATH:fallback\nname}\n$1/${1|猫\nx,é\ny|}$0!" in
  let resolve t path = N.resolve t ~path:(Some path) |> Or_error.ok_exn in
  let indent t = N.indent t ~prefix:"  " |> Or_error.ok_exn in
  let template = resolve (indent raw) "../目\n録/é.sv" in
  let equivalent = indent (resolve raw "../目\n録/é.sv") in
  [%test_eq: string] (N.text template) (N.text equivalent);
  [%test_eq: N.field list] (N.fields template) (N.fields equivalent);
  let text = buffer ("前" ^ N.text template ^ "尾") in
  let session = S.start template ~base:3 ~revision:10 ~text |> Or_error.ok_exn in
  let before = S.fields session in
  ignore (resolve template "different.sv" : N.t);
  [%test_eq: N.field list] (S.fields session) before;
  let session, text = cycle session text 10 Next in
  [%test_eq: string] (B.to_string text) "前../目\n  録/é.sv\n  é\n  y/é\n  y!尾";
  assert (S.cursor (S.navigate session Next) = B.length text - String.length "!尾")
;;

let%test_unit "choice empty mirrors preserve coincident field and final-marker ordering" =
  let session, text = start "$2$1$0${1|,猫|}$2!" in
  let session, text = cycle session text 10 Next in
  [%test_eq: string] (B.to_string text) "猫猫!";
  [%test_eq: N.field list] (S.fields session)
    [field 1 [range 0 3; range 3 6]; field 2 [range 0 0; range 6 6]];
  let session, text = cycle session text 11 Next in
  [%test_eq: string] (B.to_string text) "!";
  [%test_eq: N.range option] (S.selection session) (Some (range 0 0));
  let session, text = insert session text 12 "x" in
  [%test_eq: string] (B.to_string text) "xx!";
  let session = S.navigate session Next in
  let session, text = insert session text 13 "é" in
  [%test_eq: string] (B.to_string text) "éxxé!";
  assert (S.cursor (S.navigate session Next) = String.length "éx")
;;

let%test_unit "malformed supported variable defaults reject even before path resolution" =
  List.iter ["${TM_FILENAME"; "${TM_FILENAME:"; "${TM_FILENAME:unterminated";
    "${TM_FILENAME:trailing\\"; "${TM_FILENAME:bad\\x}";
    "${TM_FILENAME:$0}"; "${TM_FILENAME:${1:x}}";
    "${TM_FILENAME|a,b|}"; "${TM_FILENAME_BASE/no/yes/}";
    "${0:}"; "${0||}"] ~f:(fun input ->
      assert (Result.is_error (N.parse input)))
;;

let%test_unit "plain text, escapes, empty defaults and implicit final cursor" =
  let t = parse {|a\$1 \\ \} ${1:} $1 ${2} $3|} in
  [%test_eq: string] (N.text t) "a$1 \\ }    ";
  [%test_eq: N.field list] (N.fields t)
    [ field 1 [ range 8 8; range 9 9 ]; field 2 [ range 10 10 ]; field 3 [ range 11 11 ] ];
  assert (N.final_cursor t = String.length (N.text t));
  let empty = parse "" in
  assert (String.is_empty (N.text empty));
  assert (List.is_empty (N.fields empty));
  assert (N.final_cursor empty = 0)
;;

let%test_unit "code braces outside placeholders are ordinary literal text" =
  let t = parse "fn ${1:name}() {\n  $0\n}" in
  [%test_eq: string] (N.text t) "fn name() {\n  \n}";
  [%test_eq: N.field list] (N.fields t) [ field 1 [ range 3 7 ] ];
  assert (N.final_cursor t = String.length "fn name() {\n  ")
;;

let%test_unit "forward references share defaults with all occurrences, navigation is numeric" =
  let t = parse "$20/${2:中}/${20:é}/$2/$0!" in
  [%test_eq: string] (N.text t) "é/中/é/中/!";
  [%test_eq: N.field list] (N.fields t)
    [ field 2 [ range 3 6; range 10 13 ]; field 20 [ range 0 2; range 7 9 ] ];
  assert (N.final_cursor t = 14);
  [%test_eq: string] (N.text (parse "${1:hi} ${1:hi} ${1}")) "hi hi hi";
  [%test_eq: string] (N.text (parse {|${1:a\$b\}c\\d}-$1|})) "a$b}c\\d-a$b}c\\d"
;;

let%test_unit "malformed, unsupported, invalid text and nested defaults reject explicitly" =
  List.iter
    [ "$"; "${"; "${1"; "${1:"; "${1:abc"; "abc\\"; "\\x"
    ; "$NAME"; "${NAME}"; "${NAME:default}"; "${1|one,two}"; "${1/a/b/}"
    ; "${1:${2:inner}}"; "${1:$2}"; "${1:${1}}"; "${1:${0}}"
    ; "${1:x}${1:y}"; "$0$0"; "${0:no}"; "$1234567890"
    ; "\255"; "\000"; "\r"; "\r\n"
    ] ~f:(fun input -> assert (Result.is_error (N.parse input)))
;;

let%test_unit "parser input, output and occurrence budgets" =
  assert (Result.is_ok (N.parse (String.make 65_536 'x')));
  assert (Result.is_error (N.parse (String.make 65_537 'x')));
  assert (Result.is_ok (N.parse (String.concat (List.init 4096 ~f:(fun _ -> "$1")))));
  assert (Result.is_error (N.parse (String.concat (List.init 4097 ~f:(fun _ -> "$1")))));
  let expanding = "${1:" ^ String.make 512 'x' ^ "}"
    ^ String.concat (List.init 2200 ~f:(fun _ -> "$1")) in
  assert (Result.is_error (N.parse expanding));
  assert (Result.is_error (N.parse ("${1:" ^ String.make 20_000 '$' ^ "}")))
;;

let%test_unit "selected default replaced once, subsequent typing uses caret, mirrors atomic" =
  let session, text = start ~prefix:"pre:" ~suffix:":post" "${1:default} / $1$0!" in
  [%test_eq: N.range option] (S.selection session) (Some (range 4 11));
  let change = S.insert session ~revision:10 ~text "猫" |> Or_error.ok_exn in
  (* Planning is pure and has not consumed the initial selection. *)
  [%test_eq: N.range option] (S.selection session) (Some (range 4 11));
  let session, text = apply change text 11 in
  [%test_eq: string] (B.to_string text) "pre:猫 / 猫!:post";
  assert (Option.is_none (S.selection session));
  assert (S.cursor session = 7);
  let session, text = insert session text 11 "🐹" in
  [%test_eq: string] (B.to_string text) "pre:猫🐹 / 猫🐹!:post";
  assert (S.cursor session = 11);
  let session = S.set_cursor session 7 |> Or_error.ok_exn in
  let session, text = insert session text 12 "é" in
  [%test_eq: string] (B.to_string text) "pre:猫é🐹 / 猫é🐹!:post";
  assert (S.cursor session = 9);
  let session = S.navigate session Next in
  assert (S.finished session);
  assert (Option.is_none (S.selection session));
  assert (S.cursor session = B.length text - String.length "!:post");
  assert (S.finished (S.navigate session Previous))
;;

let%test_unit "numeric navigation edits occurrences before and after other fields" =
  let session, text = start ~prefix:"π|" ~suffix:"尾" "$2 ${1:猫} ${2:é} $1$0!" in
  [%test_eq: string] (B.to_string text) "π|é 猫 é 猫!尾";
  assert ((S.active session |> Option.value_exn).number = 1);
  let session, text = insert session text 10 "🐹" in
  [%test_eq: string] (B.to_string text) "π|é 🐹 é 🐹!尾";
  let session = S.navigate session Next in
  assert ((S.active session |> Option.value_exn).number = 2);
  let session, text = insert session text 11 "𝄞" in
  [%test_eq: string] (B.to_string text) "π|𝄞 🐹 𝄞 🐹!尾";
  let session = S.navigate session Previous in
  [%test_eq: N.range option] (S.selection session) (Some (range 8 12));
  let session, text = insert session text 12 "é" in
  [%test_eq: string] (B.to_string text) "π|𝄞 é 𝄞 é!尾";
  let session = S.navigate (S.navigate session Next) Next in
  assert (S.finished session);
  assert (S.cursor session = B.length text - String.length "!尾")
;;

let%test_unit "Unicode codepoint boundaries with ZWJ, combining accents and multiline edits" =
  let session, text = start "${1:👩‍💻é} -- $1" in
  assert (Result.is_error (S.set_cursor session 1));
  assert (Result.is_error (S.replace session ~revision:10 ~text ~start:0 ~stop:1 ~replacement:"x"));
  assert (Result.is_error (S.replace session ~revision:10 ~text ~start:1 ~stop:4 ~replacement:"x"));
  let session = S.set_cursor session (String.length "👩‍💻e") |> Or_error.ok_exn in
  let change = S.replace session ~revision:10 ~text
    ~start:(String.length "👩‍💻e") ~stop:(String.length "👩‍💻é") ~replacement:"" |> Or_error.ok_exn in
  let session, text = apply change text 11 in
  [%test_eq: string] (B.to_string text) "👩‍💻e -- 👩‍💻e";
  let session = S.set_cursor session 4 |> Or_error.ok_exn in
  let session, text = insert session text 11 "\n中" in
  [%test_eq: string] (B.to_string text) "👩\n中‍💻e -- 👩\n中‍💻e";
  assert (S.cursor session = 8);
  let session = S.navigate session Previous in
  [%test_eq: N.range option] (S.selection session) (Some (active_range session))
;;

let%test_unit "coincident empty stops and final marker preserve source ordering" =
  let session, text = start "$2$1$0$2$1!" in
  let session, text = insert session text 10 "a" in
  [%test_eq: string] (B.to_string text) "aa!";
  [%test_eq: N.field list] (S.fields session)
    [ field 1 [ range 0 1; range 1 2 ]; field 2 [ range 0 0; range 1 1 ] ];
  let session = S.navigate session Next in
  let session, text = insert session text 11 "中" in
  [%test_eq: string] (B.to_string text) "中a中a!";
  let session = S.navigate session Next in
  assert (S.finished session);
  assert (S.cursor session = 4);
  let session, text = start "$0$1" in
  let session, _ = insert session text 10 "x" in
  assert (S.cursor (S.navigate session Next) = 0)
;;

let%test_unit "editing a later mirror relocates the caret past changed mirrors before it" =
  let session, text = start ~prefix:"π|" "$1 / ${1:é🐹} / $1$0!" in
  let middle = (S.active session |> Option.value_exn).ranges |> Fn.flip List.nth_exn 1 in
  let session = S.set_cursor session (middle.start + 2) |> Or_error.ok_exn in
  [%test_eq: N.range option] (S.active_range session) (Some middle);
  let session, text = insert session text 10 "中" in
  [%test_eq: string] (B.to_string text) "π|é中🐹 / é中🐹 / é中🐹!";
  (* The first mirror grew by three bytes before the caret's own insertion. *)
  assert (S.cursor session = middle.start + 3 + 2 + 3);
  let middle = S.active_range session |> Option.value_exn in
  let change = S.replace session ~revision:11 ~text
    ~start:middle.start ~stop:middle.stop ~replacement:"x" |> Or_error.ok_exn in
  let session, text = apply change text 12 in
  [%test_eq: string] (B.to_string text) "π|x / x / x!";
  assert (S.cursor session = String.length "π|x / x");
  let session, text = insert session text 12 "́" in
  [%test_eq: string] (B.to_string text) "π|x́ / x́ / x́!";
  assert (S.cursor session = String.length "π|x́ / x́");
  assert (S.cursor (S.navigate session Next) = B.length text - 1)
;;

let%test_unit "explicit replacements delete fields, reselecting empty fields remains usable" =
  let session, text = start "${1:abc}=$1 ${2:q}" in
  let change = S.replace session ~revision:10 ~text ~start:1 ~stop:2 ~replacement:"XYZ"
    |> Or_error.ok_exn in
  let session, text = apply change text 11 in
  [%test_eq: string] (B.to_string text) "aXYZc=aXYZc q";
  assert (S.cursor session = 4);
  let session = S.navigate session Previous in
  let session, text = insert session text 11 "" in
  [%test_eq: string] (B.to_string text) "= q";
  let session, text = insert session text 12 "z" in
  [%test_eq: string] (B.to_string text) "z=z q";
  assert (S.cursor session = 1);
  let session = S.navigate session Next in
  [%test_eq: N.range option] (S.selection session) (Some (range 4 5))
;;

let%test_unit "stale snapshots, revision mismatches, invalid bases and out-of-field edits reject" =
  let session, text = start "${1:é}=${2:q}" in
  assert (Result.is_error (S.insert session ~revision:9 ~text "x"));
  assert (Result.is_error (S.insert session ~revision:10 ~text:(buffer "é=Q") "x"));
  assert (Result.is_error (S.insert session ~revision:10 ~text "\255"));
  assert (Result.is_error (S.replace session ~revision:10 ~text ~start:(-1) ~stop:0 ~replacement:""));
  assert (Result.is_error (S.replace session ~revision:10 ~text ~start:0 ~stop:3 ~replacement:""));
  assert (Result.is_error (S.replace session ~revision:10 ~text ~start:2 ~stop:0 ~replacement:""));
  List.iter [ -1; 1; 4; Int.max_value ] ~f:(fun base ->
    assert (Result.is_error (S.start (parse "é") ~base ~revision:0 ~text)));
  assert (Result.is_error (S.start (parse "other") ~base:0 ~revision:0 ~text));
  let done_ = S.navigate (S.navigate session Next) Next in
  assert (Result.is_error (S.insert done_ ~revision:10 ~text "x"));
  assert (Result.is_error (S.set_cursor done_ 0))
;;

let%test_unit "sessions without positive fields finish immediately at explicit or implicit cursor" =
  let session, _ = start ~prefix:"中" "a$0b" in
  assert (S.finished session && S.cursor session = 4);
  assert (Option.is_none (S.active session));
  let session, _ = start "plain" in
  assert (S.finished session && S.cursor session = 5)
;;

let%test_unit "session expansion is bounded after mirror multiplication" =
  let session, text = start (String.concat (List.init 4096 ~f:(fun _ -> "$1"))) in
  assert (Result.is_error (S.insert session ~revision:10 ~text (String.make 257 'x')));
  let session, text = insert session text 10 (String.make 256 'x') in
  assert (B.length text = 1_048_576);
  assert (Result.is_error (S.insert session ~revision:11 ~text "x"))
;;

let%test_unit "bounded adversarial grammar corpus never raises and ranges always valid" =
  let alphabet = [| '$'; '{'; '}'; ':'; '\\'; '0'; '1'; '9'; '|'; '/'; 'x' |] in
  for seed = 0 to 3999 do
    let state = ref (seed + 1) in
    let input = String.init (seed % 80) ~f:(fun _ ->
      state := (!state * 48271) mod 2147483647;
      alphabet.(!state % Array.length alphabet)) in
    match N.parse input with
    | Error _ -> ()
    | Ok snippet ->
      let text = buffer (N.text snippet) in
      assert (B.is_boundary text (N.final_cursor snippet));
      List.iter (N.fields snippet) ~f:(fun field ->
        List.iter field.ranges ~f:(fun r ->
          assert (r.start <= r.stop && B.is_boundary text r.start && B.is_boundary text r.stop)))
  done
;;
