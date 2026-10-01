open! Core
open Ches_core
module B = Text_buffer

let of_string_exn s =
  B.of_string s |> Result.map_error ~f:B.Invalid_text.to_string_hum |> Result.ok_or_failwith
;;

let insert_exn t ~at s =
  B.insert t ~at s |> Result.map_error ~f:B.Invalid_text.to_string_hum |> Result.ok_or_failwith
;;

let print_lines t =
  printf "length=%d lines=%d\n" (B.length t) (B.line_count t);
  for line = 0 to B.line_count t - 1 do
    printf "%d [%d,%d) |%s|\n" line (B.line_start t line) (B.line_end t line) (B.line_text t line)
  done
;;

let show_raise f =
  match f () with
  | (_ : _) -> print_endline "did not raise"
  | exception exn -> print_s [%sexp (exn : exn)]
;;

let boundaries t = List.filter (List.range 0 (B.length t) ~stop:`inclusive) ~f:(B.is_boundary t)

let%expect_test "empty text is one empty line" =
  let t = B.empty in
  print_lines t;
  [%expect
    {|
    length=0 lines=1
    0 [0,0) ||
    |}];
  print_s
    [%sexp
      { equal_of_string = (B.equal t (of_string_exn "") : bool)
      ; line_of_offset_0 = (B.line_of_offset t 0 : int)
      ; prev = (B.prev_boundary t 0 : int option)
      ; next = (B.next_boundary t 0 : int option)
      }];
  [%expect {| ((equal_of_string true) (line_of_offset_0 0) (prev ()) (next ())) |}]
;;

let%expect_test "no trailing LF" =
  print_lines (of_string_exn "ab\ncd");
  [%expect
    {|
    length=5 lines=2
    0 [0,2) |ab|
    1 [3,5) |cd|
    |}]
;;

let%expect_test "trailing LF creates an empty final line" =
  print_lines (of_string_exn "ab\n");
  [%expect
    {|
    length=3 lines=2
    0 [0,2) |ab|
    1 [3,3) ||
    |}];
  print_lines (of_string_exn "\n");
  [%expect
    {|
    length=1 lines=2
    0 [0,0) ||
    1 [1,1) ||
    |}]
;;

let%expect_test "consecutive empty lines" =
  print_lines (of_string_exn "a\n\n\nb");
  [%expect
    {|
    length=5 lines=4
    0 [0,1) |a|
    1 [2,2) ||
    2 [3,3) ||
    3 [4,5) |b|
    |}]
;;

let%expect_test "line_of_offset at first, newline, and last positions" =
  let t = of_string_exn "ab\n\ncd\n" in
  List.iter (boundaries t) ~f:(fun offset ->
    printf "%d -> line %d\n" offset (B.line_of_offset t offset));
  [%expect
    {|
    0 -> line 0
    1 -> line 0
    2 -> line 0
    3 -> line 1
    4 -> line 2
    5 -> line 2
    6 -> line 2
    7 -> line 3
    |}]
;;

(* a = 1 byte, é = 2, 日 = 3, 🐹 = 4 *)
let%expect_test "multibyte boundaries" =
  let t = of_string_exn "aé日🐹\nx" in
  print_lines t;
  [%expect
    {|
    length=12 lines=2
    0 [0,10) |aé日🐹|
    1 [11,12) |x|
    |}];
  print_s [%sexp (boundaries t : int list)];
  [%expect {| (0 1 3 6 10 11 12) |}];
  let rec walk offset ~step =
    match step t offset with
    | None -> []
    | Some next -> next :: walk next ~step
  in
  print_s [%sexp (walk 0 ~step:B.next_boundary : int list)];
  [%expect {| (1 3 6 10 11 12) |}];
  print_s [%sexp (walk (B.length t) ~step:B.prev_boundary : int list)];
  [%expect {| (11 10 6 3 1 0) |}];
  print_endline (B.slice t ~pos:3 ~len:7);
  [%expect {| 日🐹 |}];
  print_s
    [%sexp
      (List.map (boundaries t) ~f:(B.column_of_offset t) : int list)
    , (List.map [ 0; 1; 2; 3; 4; 5 ] ~f:(B.offset_of_column t ~line:0) : int list)
    , (B.offset_of_column t ~line:1 99 : int)];
  [%expect {| ((0 1 2 3 4 0 1) (0 1 3 6 10 10) 12) |}]
;;

let%expect_test "insert within a line, and inserting newlines splits lines" =
  let t = of_string_exn "hello\nworld" in
  print_lines (insert_exn t ~at:5 "!");
  [%expect
    {|
    length=12 lines=2
    0 [0,6) |hello!|
    1 [7,12) |world|
    |}];
  print_lines (insert_exn t ~at:2 "X\nY");
  [%expect
    {|
    length=14 lines=3
    0 [0,3) |heX|
    1 [4,8) |Yllo|
    2 [9,14) |world|
    |}];
  print_lines (insert_exn t ~at:(B.length t) "\n");
  [%expect
    {|
    length=12 lines=3
    0 [0,5) |hello|
    1 [6,11) |world|
    2 [12,12) ||
    |}];
  print_lines (insert_exn B.empty ~at:0 "日本");
  [%expect
    {|
    length=6 lines=1
    0 [0,6) |日本|
    |}]
;;

let%expect_test "delete across newlines joins lines" =
  let t = of_string_exn "ab\ncd\nef" in
  (* the LF alone *)
  print_lines (B.delete t ~pos:2 ~len:1);
  [%expect
    {|
    length=7 lines=2
    0 [0,4) |abcd|
    1 [5,7) |ef|
    |}];
  (* "b\ncd\ne" spans two LFs *)
  print_lines (B.delete t ~pos:1 ~len:6);
  [%expect
    {|
    length=2 lines=1
    0 [0,2) |af|
    |}];
  (* a whole multibyte code point *)
  let u = of_string_exn "a日b" in
  print_endline (B.to_string (B.delete u ~pos:1 ~len:3));
  [%expect {| ab |}];
  print_lines (B.delete t ~pos:0 ~len:(B.length t));
  [%expect
    {|
    length=0 lines=1
    0 [0,0) ||
    |}]
;;

let%expect_test "to_string preserves text exactly" =
  List.iter [ ""; "x"; "x\n"; "x\n\n"; "\n\nx"; "\ttab é\n" ] ~f:(fun s ->
    assert (String.equal (B.to_string (of_string_exn s)) s));
  [%expect {| |}]
;;

let%expect_test "rejected input" =
  let show s =
    match B.of_string s with
    | Ok _ -> printf "%S: accepted\n" s
    | Error e -> printf "%S: %s\n" s (B.Invalid_text.to_string_hum e)
  in
  List.iter
    [ "ok\xff"
    ; "\xe6\x97" (* truncated 3-byte sequence *)
    ; "\xc0\xaf" (* overlong encoding of '/' *)
    ; "\xed\xa0\x80" (* UTF-16 surrogate *)
    ; "\x80" (* lone continuation byte *)
    ; "a\r\nb"
    ; "a\rb"
    ; "end\r"
    ; "a\000b"
    ; "\t\x1b[31m" (* other control characters are valid text *)
    ]
    ~f:show;
  [%expect
    {|
    "ok\255": invalid UTF-8 at byte offset 2
    "\230\151": invalid UTF-8 at byte offset 0
    "\192\175": invalid UTF-8 at byte offset 0
    "\237\160\128": invalid UTF-8 at byte offset 0
    "\128": invalid UTF-8 at byte offset 0
    "a\r\nb": CRLF line ending (only LF line endings are supported) at byte offset 1
    "a\rb": carriage return (only LF line endings are supported) at byte offset 1
    "end\r": carriage return (only LF line endings are supported) at byte offset 3
    "a\000b": NUL byte at byte offset 1
    "\t\027[31m": accepted
    |}];
  (* Inserted text follows the same rules; offsets are relative to the inserted string. *)
  let t = of_string_exn "abc" in
  print_s [%sexp (B.insert t ~at:1 "x\r\n" : (_, B.Invalid_text.t) Result.t)];
  [%expect {| (Error ((reason Crlf) (offset 1))) |}];
  print_s [%sexp (B.insert t ~at:1 "\xff" : (_, B.Invalid_text.t) Result.t)];
  [%expect {| (Error ((reason Invalid_utf8) (offset 0))) |}]
;;

let%expect_test "invalid offsets, lengths, and lines raise" =
  let t = of_string_exn "a日\nb" in
  (* boundaries: 0 1 4 5 6 *)
  show_raise (fun () -> B.insert t ~at:2 "x");
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.insert: offset 2 is not a code-point boundary in [0, 6]")
    |}];
  show_raise (fun () -> B.insert t ~at:7 "x");
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.insert: offset 7 is not a code-point boundary in [0, 6]")
    |}];
  (* An invalid offset raises even when the text is also invalid. *)
  show_raise (fun () -> B.insert t ~at:(-1) "\r");
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.insert: offset -1 is not a code-point boundary in [0, 6]")
    |}];
  show_raise (fun () -> B.delete t ~pos:0 ~len:2);
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.delete: offset 2 is not a code-point boundary in [0, 6]")
    |}];
  show_raise (fun () -> B.delete t ~pos:4 ~len:(-1));
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.delete: length -1 from offset 4 is outside [0, 6]")
    |}];
  show_raise (fun () -> B.slice t ~pos:5 ~len:2);
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.slice: length 2 from offset 5 is outside [0, 6]")
    |}];
  show_raise (fun () -> B.slice t ~pos:0 ~len:Int.max_value);
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.slice: length 4611686018427387903 from offset 0 is outside [0, 6]")
    |}];
  show_raise (fun () -> B.line_start t 2);
  [%expect {| (Invalid_argument "Text_buffer.line_start: line 2 is outside [0, 2)") |}];
  show_raise (fun () -> B.line_end t (-1));
  [%expect {| (Invalid_argument "Text_buffer.line_end: line -1 is outside [0, 2)") |}];
  show_raise (fun () -> B.line_of_offset t 3);
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.line_of_offset: offset 3 is not a code-point boundary in [0, 6]")
    |}];
  show_raise (fun () -> B.next_boundary t 3);
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.next_boundary: offset 3 is not a code-point boundary in [0, 6]")
    |}];
  show_raise (fun () -> B.prev_boundary t 7);
  [%expect
    {|
    (Invalid_argument
     "Text_buffer.prev_boundary: offset 7 is not a code-point boundary in [0, 6]")
    |}];
  (* The buffer is untouched after all of that. *)
  print_lines t;
  [%expect
    {|
    length=6 lines=2
    0 [0,4) |a日|
    1 [5,6) |b|
    |}]
;;

(* Property tests against naive reference computations on the whole string. *)

let gen_text =
  Quickcheck.Generator.(
    list (of_list [ "a"; "b"; " "; "\t"; "\n"; "é"; "日"; "🐹" ]) |> map ~f:String.concat)
;;

let code_point_starts s =
  let rec loop i acc =
    if i >= String.length s
    then List.rev (i :: acc)
    else
      loop
        (i + Stdlib.Uchar.utf_decode_length (Stdlib.String.get_utf_8_uchar s i))
        (i :: acc)
  in
  loop 0 []
;;

let check_against_reference t =
  let s = B.to_string t in
  let expected_lines = String.split s ~on:'\n' in
  [%test_result: string list]
    (List.init (B.line_count t) ~f:(B.line_text t))
    ~expect:expected_lines;
  let starts = code_point_starts s in
  [%test_result: int list] (boundaries t) ~expect:starts;
  List.iter starts ~f:(fun offset ->
    let line = B.line_of_offset t offset in
    [%test_result: int]
      line
      ~expect:(String.count (String.prefix s offset) ~f:(Char.equal '\n'));
    assert (B.line_start t line <= offset && offset <= B.line_end t line);
    let column = B.column_of_offset t offset in
    [%test_result: int]
      column
      ~expect:
        (List.count starts ~f:(fun o -> o >= B.line_start t line && o < offset));
    [%test_result: int] (B.offset_of_column t ~line column) ~expect:offset);
  for line = 0 to B.line_count t - 1 do
    [%test_result: int]
      (B.offset_of_column t ~line (String.length s + 1))
      ~expect:(B.line_end t line)
  done;
  List.iter2_exn (List.drop_last_exn starts) (List.tl_exn starts) ~f:(fun a b ->
    [%test_result: int option] (B.next_boundary t a) ~expect:(Some b);
    [%test_result: int option] (B.prev_boundary t b) ~expect:(Some a))
;;

let pick list i = List.nth_exn list (i % List.length list)

let%test_unit "line and boundary queries agree with a naive reference" =
  Quickcheck.test gen_text ~sexp_of:[%sexp_of: string] ~f:(fun s ->
    check_against_reference (of_string_exn s))
;;

let%test_unit "insert preserves untouched text and keeps line data consistent" =
  Quickcheck.test
    (Quickcheck.Generator.tuple3 gen_text Int.quickcheck_generator gen_text)
    ~sexp_of:[%sexp_of: string * int * string]
    ~f:(fun (s, i, inserted) ->
      let t = of_string_exn s in
      let at = pick (boundaries t) i in
      let t' = insert_exn t ~at inserted in
      [%test_result: string]
        (B.to_string t')
        ~expect:(String.prefix s at ^ inserted ^ String.drop_prefix s at);
      check_against_reference t')
;;

let%test_unit "delete preserves untouched text and keeps line data consistent" =
  Quickcheck.test
    (Quickcheck.Generator.tuple3 gen_text Int.quickcheck_generator Int.quickcheck_generator)
    ~sexp_of:[%sexp_of: string * int * int]
    ~f:(fun (s, i, j) ->
      let t = of_string_exn s in
      let a = pick (boundaries t) i in
      let b = pick (boundaries t) j in
      let pos = Int.min a b in
      let len = Int.abs (a - b) in
      let t' = B.delete t ~pos ~len in
      [%test_result: string]
        (B.to_string t')
        ~expect:(String.prefix s pos ^ String.drop_prefix s (pos + len));
      [%test_result: string] (B.slice t ~pos ~len) ~expect:(String.sub s ~pos ~len);
      check_against_reference t')
;;
