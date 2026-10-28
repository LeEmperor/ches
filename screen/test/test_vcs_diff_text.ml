(* Pure tests of Vcs_diff_text.span (phase 4): the diff lines a Visual selection's byte
   range touches, over a diff parsed by Diff_output (literal git 2.43 output). *)

open! Core
open Ches_screen
module Diff = Ches_vcs.Diff

let diff =
  {|diff --git a/a.txt b/a.txt
index 1111111..2222222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
-one
+ONE
 two
 three
@@ -10,2 +10,3 @@ nine
 ten
+eleven
 twelve
\ No newline at end of file
diff --git a/b.txt b/b.txt
index 3333333..4444444 100644
--- a/b.txt
+++ b/b.txt
@@ -1 +1 @@
-bee
+BEE
|}
  |> Ches_vcs_git.Diff_output.parse Diff.Limits.default ~cut:false
  |> Or_error.ok_exn
;;

let text = Vcs_diff_text.of_diff diff

(* The byte offset of column [col] of line [line] of [text]. *)
let at ?(text = text) line col =
  List.fold
    (List.take (Vcs_diff_text.lines text) line)
    ~init:col
    ~f:(fun offset (l : Vcs_diff_text.Line.t) -> offset + String.length l.text + 1)
;;

let show ?(text = text) start stop =
  print_s
    [%sexp
      (Vcs_diff_text.span text ~start ~stop
       : (Vcs_diff_text.Span.t option, [ `Several_files ]) Result.t)]
;;

let%expect_test "the layout the offsets below refer to" =
  List.iteri (Vcs_diff_text.lines text) ~f:(fun i (line : Vcs_diff_text.Line.t) ->
    printf "%2d|%s\n" i line.text);
  [%expect
    {|
     0|diff --git a/a.txt b/a.txt
     1|index 1111111..2222222 100644
     2|--- a/a.txt
     3|+++ b/a.txt
     4|@@ -1,3 +1,3 @@
     5|-one
     6|+ONE
     7| two
     8| three
     9|@@ -10,2 +10,3 @@ nine
    10| ten
    11|+eleven
    12| twelve
    13|\ No newline at end of file
    14|diff --git a/b.txt b/b.txt
    15|index 3333333..4444444 100644
    16|--- a/b.txt
    17|+++ b/b.txt
    18|@@ -1 +1 @@
    19|-bee
    20|+BEE
    |}]
;;

let%expect_test "linewise and characterwise ranges in one hunk" =
  (* Linewise: whole lines, each with its line feed. *)
  show (at 5 0) (at 7 0);
  show (at 6 0) (at 7 0);
  (* Characterwise, partial lines at both ends. *)
  show (at 5 2) (at 7 1);
  (* Ending on a line feed: that line counts, the next one does not. *)
  show (at 5 0) (at 6 0);
  show (at 6 0 - 1) (at 6 0);
  (* Empty: the line holding [start]. *)
  show (at 7 3) (at 7 3);
  [%expect
    {|
    (Ok (((file 0) (hunks ((0 (0 1)))))))
    (Ok (((file 0) (hunks ((0 (1)))))))
    (Ok (((file 0) (hunks ((0 (0 1 2)))))))
    (Ok (((file 0) (hunks ((0 (0)))))))
    (Ok (((file 0) (hunks ((0 (0)))))))
    (Ok (((file 0) (hunks ((0 (2)))))))
    |}]
;;

let%expect_test "header and @@ lines belong to the file but list no hunk" =
  show (at 0 0) (at 5 0);
  show (at 9 0) (at 10 0);
  show (at 2 3) (at 2 4);
  (* An @@ line with lines of its hunk: only the lines. *)
  show (at 4 0) (at 6 0);
  [%expect
    {|
    (Ok (((file 0) (hunks ()))))
    (Ok (((file 0) (hunks ()))))
    (Ok (((file 0) (hunks ()))))
    (Ok (((file 0) (hunks ((0 (0)))))))
    |}]
;;

let%expect_test "two hunks of one file; the no-newline marker; the last line" =
  show (at 8 0) (at 11 2);
  show (at 12 0) (at 14 0);
  show (at 19 1) (String.length (Vcs_diff_text.text text));
  [%expect
    {|
    (Ok (((file 0) (hunks ((0 (3)) (1 (0 1)))))))
    (Ok (((file 0) (hunks ((1 (2 3)))))))
    (Ok (((file 1) (hunks ((0 (0 1)))))))
    |}]
;;

let%expect_test "a second file's lines, its header lines included, make several files" =
  show (at 13 0) (at 14 1);
  show (at 12 0) (at 19 0);
  show 0 (String.length (Vcs_diff_text.text text));
  (* The line feed ending the first file is still the first file's. *)
  show (at 13 0) (at 14 0);
  [%expect
    {|
    (Error Several_files)
    (Error Several_files)
    (Error Several_files)
    (Ok (((file 0) (hunks ((1 (3)))))))
    |}]
;;

let%expect_test "lines outside any file are ignored" =
  let message = Vcs_diff_text.of_message "No changes" in
  show ~text:message 0 3;
  (* A commit's preamble before the file, and the cut note after it. *)
  let shown =
    Vcs_diff_text.of_diff
      { Diff.preamble = [ "commit 0123456789abcdef"; ""; "    Message" ]
      ; files = [ List.hd_exn diff.files ]
      ; cut = true
      }
  in
  let at = at ~text:shown in
  show ~text:shown (at 0 0) (at 3 0);
  show ~text:shown (at 1 0) (at 9 0);
  show ~text:shown (at 16 0) (at 17 3);
  [%expect
    {|
    (Ok ())
    (Ok ())
    (Ok (((file 0) (hunks ((0 (0)))))))
    (Ok (((file 0) (hunks ((1 (3)))))))
    |}]
;;
