open! Core
open Ches_vcs
module Capture = Ches_vcs_host.Capture

let feed_all chunks =
  let lines = Capture.Lines.create () in
  let f (line : Event.Line.t) =
    print_s
      [%sexp
        (line.text : string), (if line.transient then "transient" else "line" : string)]
  in
  List.iter chunks ~f:(fun chunk ->
    let bytes = Bytes.of_string chunk in
    Capture.Lines.feed lines bytes ~pos:0 ~len:(Bytes.length bytes) ~f);
  Capture.Lines.finish lines ~f
;;

let%expect_test "lines: newline, carriage return, CRLF, chunk boundaries, end of file" =
  feed_all [ "one\ntw"; "o\n"; "Receiving 45%\r"; "Receiving 100%, done.\n" ];
  [%expect
    {|
    (one line)
    (two line)
    ("Receiving 45%" transient)
    ("Receiving 100%, done." line)
    |}];
  (* CRLF: the line is reported at the CR (it may be a progress update) and again,
     permanent, at the LF, even across chunks. *)
  feed_all [ "hook output\r"; "\nnext\r\r\n"; "\n"; "last" ];
  [%expect
    {|
    ("hook output" transient)
    ("hook output" line)
    (next transient)
    ("" transient)
    ("" line)
    ("" line)
    (last line)
    |}]
;;

let%expect_test "lines: long lines are reported in 4 KiB pieces" =
  let lines = Capture.Lines.create () in
  let f (line : Event.Line.t) =
    print_s [%sexp (String.length line.text : int), (line.transient : bool)]
  in
  let feed s =
    Capture.Lines.feed lines (Bytes.of_string s) ~pos:0 ~len:(String.length s) ~f
  in
  feed (String.make Capture.Lines.max_line 'a' ^ "\n");
  feed (String.make (Capture.Lines.max_line + 1) 'b' ^ "\n");
  feed (String.make (2 * Capture.Lines.max_line) 'c');
  Capture.Lines.finish lines ~f;
  [%expect
    {|
    (4096 false)
    (4096 false)
    (1 false)
    (4096 false)
    (4096 false)
    |}]
;;

let%expect_test "head keeps the first bytes, tail the last" =
  let head = Capture.Head.create ~limit:5 in
  let tail = Capture.Tail.create ~limit:5 in
  List.iter [ "abc"; "def"; "ghi"; "" ] ~f:(fun chunk ->
    let bytes = Bytes.of_string chunk in
    let state = Capture.Head.add head bytes ~pos:0 ~len:(Bytes.length bytes) in
    Capture.Tail.add tail bytes ~pos:0 ~len:(Bytes.length bytes);
    print_s [%sexp (state : [ `Within | `Passed_limit | `Beyond ])]);
  print_s
    [%sexp
      { head = (Capture.Head.contents head : string)
      ; head_truncated = (Capture.Head.truncated head : bool)
      ; tail = (Capture.Tail.contents tail : string)
      ; tail_truncated = (Capture.Tail.truncated tail : bool)
      }];
  [%expect
    {|
    Within
    Passed_limit
    Beyond
    Beyond
    ((head abcde) (head_truncated true) (tail efghi) (tail_truncated true))
    |}];
  (* Exactly at the limit is not truncated; a chunk larger than the limit keeps its own
     tail; the tail stays right across many compactions. *)
  let tail = Capture.Tail.create ~limit:3 in
  Capture.Tail.add tail (Bytes.of_string "xyz") ~pos:0 ~len:3;
  print_s
    [%sexp (Capture.Tail.contents tail : string), (Capture.Tail.truncated tail : bool)];
  Capture.Tail.add tail (Bytes.of_string "0123456789") ~pos:2 ~len:7;
  print_s
    [%sexp (Capture.Tail.contents tail : string), (Capture.Tail.truncated tail : bool)];
  for i = 0 to 99 do
    Capture.Tail.add tail (Bytes.of_string (Int.to_string (i % 10))) ~pos:0 ~len:1
  done;
  print_s [%sexp (Capture.Tail.contents tail : string)];
  [%expect {|
    (xyz false)
    (678 true)
    789
    |}]
;;
