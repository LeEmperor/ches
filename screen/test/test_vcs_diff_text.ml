(* Pure tests of Vcs_diff_text over diffs parsed by Diff_output (literal git 2.43
   output): span (phase 4), the diff lines a Visual selection's byte range touches; a
   commit's file list, file_starts and listed_file_at (phase 8). *)

open! Core
open Ches_screen
module Diff = Ches_vcs.Diff

let output =
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
;;

let diff =
  Ches_vcs_git.Diff_output.parse Diff.Limits.default ~cut:false output
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
  (* A commit's preamble and file list (lines 0-5) before the file, and the cut note
     after it. *)
  let shown =
    Vcs_diff_text.of_diff
      { Diff.preamble = [ "commit 0123456789abcdef"; ""; "    Message" ]
      ; files = [ List.hd_exn diff.files ]
      ; cut = true
      }
  in
  let at = at ~text:shown in
  show ~text:shown (at 0 0) (at 6 0);
  show ~text:shown (at 1 0) (at 12 0);
  show ~text:shown (at 19 0) (at 20 3);
  [%expect
    {|
    (Ok ())
    (Ok ())
    (Ok (((file 0) (hunks ((0 (0)))))))
    (Ok (((file 0) (hunks ((1 (3)))))))
    |}]
;;

(* Phase 8: a commit's file list. *)

let parse ?(limits = Diff.Limits.default) output =
  Ches_vcs_git.Diff_output.parse limits ~cut:false output |> Or_error.ok_exn
;;

let header =
  {|commit 43d2480ac115bf1972d7720a59c166d6d474175c
Author:     Ches Test <ches-test@example.invalid>
AuthorDate: 2026-01-01T00:00:00+00:00
Commit:     Ches Test <ches-test@example.invalid>
CommitDate: 2026-01-01T00:00:00+00:00

|}
;;

(* Each line: [F] at a [file_starts] offset, [@] at a [hunk_starts] one; its kind;
   [listed_file_at] its start; its text. *)
let print_layout text =
  let file_starts = Vcs_diff_text.file_starts text in
  let hunk_starts = Vcs_diff_text.hunk_starts text in
  ignore
    (List.foldi
       (Vcs_diff_text.lines text)
       ~init:0
       ~f:(fun i offset (line : Vcs_diff_text.Line.t) ->
         printf
           "%2d %s%s %-10s %-2s|%s\n"
           i
           (if List.mem file_starts offset ~equal:Int.equal then "F" else " ")
           (if List.mem hunk_starts offset ~equal:Int.equal then "@" else " ")
           (Sexp.to_string [%sexp (line.kind : Vcs_diff_text.Kind.t)])
           (Option.value_map
              (Vcs_diff_text.listed_file_at text offset)
              ~default:""
              ~f:Int.to_string)
           line.text;
         offset + String.length line.text + 1)
     : int)
;;

let renamed =
  parse
    (header
     ^ {|    Rename and edit

diff --git a/b.txt b/b.txt
index 422c2b7..7be73ce 100644
--- a/b.txt
+++ b/b.txt
@@ -1,2 +1,3 @@
 a
-b
+B
+c
diff --git a/old.txt b/new.txt
similarity index 79%
rename from old.txt
rename to new.txt
index b2f931a..17eb8c9 100644
--- a/old.txt
+++ b/new.txt
@@ -2,4 +2,4 @@ one
 two
 three
 four
-five
+FIVE
|})
;;

let%expect_test "a two-file commit, one renamed: the list between message and files" =
  let text = Vcs_diff_text.of_diff renamed in
  print_layout text;
  [%expect {|
     0    Preamble     |commit 43d2480ac115bf1972d7720a59c166d6d474175c
     1    Preamble     |Author:     Ches Test <ches-test@example.invalid>
     2    Preamble     |AuthorDate: 2026-01-01T00:00:00+00:00
     3    Preamble     |Commit:     Ches Test <ches-test@example.invalid>
     4    Preamble     |CommitDate: 2026-01-01T00:00:00+00:00
     5    Message      |
     6    Message      |    Rename and edit
     7    Message      |
     8    Listed     0 |M b.txt  +2 -1
     9    Listed     1 |R new.txt  +1 -1
    10    Message      |
    11 F  Meta         |diff --git a/b.txt b/b.txt
    12    Meta         |index 422c2b7..7be73ce 100644
    13    Meta         |--- a/b.txt
    14    Meta         |+++ b/b.txt
    15  @ Hunk         |@@ -1,2 +1,3 @@
    16    Context      | a
    17    Removed      |-b
    18    Added        |+B
    19    Added        |+c
    20 F  Meta         |diff --git a/old.txt b/new.txt
    21    Meta         |similarity index 79%
    22    Meta         |rename from old.txt
    23    Meta         |rename to new.txt
    24    Meta         |index b2f931a..17eb8c9 100644
    25    Meta         |--- a/old.txt
    26    Meta         |+++ b/new.txt
    27  @ Hunk         |@@ -2,4 +2,4 @@ one
    28    Context      | two
    29    Context      | three
    30    Context      | four
    31    Removed      |-five
    32    Added        |+FIVE
    |}];
  (* A listed line's target is its file's, with no line; it has no position. *)
  List.iter (Vcs_diff_text.lines text) ~f:(fun line ->
    if Vcs_diff_text.Kind.equal line.kind Listed
    then print_s [%sexp (line.target : Vcs_diff_text.Target.t option)]);
  let offset = String.substr_index_exn (Vcs_diff_text.text text) ~pattern:"R new.txt" in
  print_s
    [%sexp (Vcs_diff_text.position_at text offset : Vcs_diff_text.Position.t option)];
  [%expect {|
    (((path (b.txt)) (display b.txt) (line ())))
    (((path (new.txt)) (display new.txt) (line ())))
    ()
    |}]
;;

let%expect_test "binary and header-only files are listed without counts" =
  let diff =
    parse
      (header
       ^ {|    Binary and gone

diff --git a/bin.dat b/bin.dat
new file mode 100644
index 0000000..8352675
Binary files /dev/null and b/bin.dat differ
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index b023018..0000000
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
diff --git a/run.sh b/run.sh
old mode 100644
new mode 100755
|})
  in
  print_layout (Vcs_diff_text.of_diff diff);
  [%expect {|
     0    Preamble     |commit 43d2480ac115bf1972d7720a59c166d6d474175c
     1    Preamble     |Author:     Ches Test <ches-test@example.invalid>
     2    Preamble     |AuthorDate: 2026-01-01T00:00:00+00:00
     3    Preamble     |Commit:     Ches Test <ches-test@example.invalid>
     4    Preamble     |CommitDate: 2026-01-01T00:00:00+00:00
     5    Message      |
     6    Message      |    Binary and gone
     7    Message      |
     8    Listed     0 |A bin.dat
     9    Listed     1 |D gone.txt  +0 -1
    10    Listed     2 |M run.sh
    11    Message      |
    12 F  Meta         |diff --git a/bin.dat b/bin.dat
    13    Meta         |new file mode 100644
    14    Meta         |index 0000000..8352675
    15    Meta         |Binary files /dev/null and b/bin.dat differ
    16 F  Meta         |diff --git a/gone.txt b/gone.txt
    17    Meta         |deleted file mode 100644
    18    Meta         |index b023018..0000000
    19    Meta         |--- a/gone.txt
    20    Meta         |+++ /dev/null
    21  @ Hunk         |@@ -1 +0,0 @@
    22    Removed      |-bye
    23 F  Meta         |diff --git a/run.sh b/run.sh
    24    Meta         |old mode 100644
    25    Meta         |new mode 100755
    |}]
;;

let%expect_test "a merge commit's combined diff counts its Added and Removed lines" =
  let diff =
    parse
      {|commit b679207734298a2f5b68b81f6e8dce3e4700a1b3
Merge: d855c43 9e2ff15
Author:     Ches Test <ches-test@example.invalid>
AuthorDate: 2026-01-01T00:00:00+00:00
Commit:     Ches Test <ches-test@example.invalid>
CommitDate: 2026-01-01T00:00:00+00:00

    Merge side

diff --cc b.txt
index af70335,f794161..bd9d3b5
--- a/b.txt
+++ b/b.txt
@@@ -1,3 -1,3 +1,3 @@@
  a
- MAIN
 -SIDE
++BOTH
  c
|}
  in
  print_layout (Vcs_diff_text.of_diff diff);
  [%expect {|
     0    Preamble     |commit b679207734298a2f5b68b81f6e8dce3e4700a1b3
     1    Preamble     |Merge: d855c43 9e2ff15
     2    Preamble     |Author:     Ches Test <ches-test@example.invalid>
     3    Preamble     |AuthorDate: 2026-01-01T00:00:00+00:00
     4    Preamble     |Commit:     Ches Test <ches-test@example.invalid>
     5    Preamble     |CommitDate: 2026-01-01T00:00:00+00:00
     6    Message      |
     7    Message      |    Merge side
     8    Message      |
     9    Listed     0 |M b.txt  +1 -2
    10    Message      |
    11 F  Meta         |diff --cc b.txt
    12    Meta         |index af70335,f794161..bd9d3b5
    13    Meta         |--- a/b.txt
    14    Meta         |+++ b/b.txt
    15  @ Hunk         |@@@ -1,3 -1,3 +1,3 @@@
    16    Context      |  a
    17    Removed      |- MAIN
    18    Removed      | -SIDE
    19    Added        |++BOTH
    20    Context      |  c
    |}]
;;

let%expect_test "a truncated file: counts over its shown hunks, then (truncated)" =
  let diff =
    parse
      ~limits:{ file_lines = 4; file_bytes = 1_000_000 }
      (header ^ "    Two files\n\n" ^ output)
  in
  print_layout (Vcs_diff_text.of_diff diff);
  [%expect {|
     0    Preamble     |commit 43d2480ac115bf1972d7720a59c166d6d474175c
     1    Preamble     |Author:     Ches Test <ches-test@example.invalid>
     2    Preamble     |AuthorDate: 2026-01-01T00:00:00+00:00
     3    Preamble     |Commit:     Ches Test <ches-test@example.invalid>
     4    Preamble     |CommitDate: 2026-01-01T00:00:00+00:00
     5    Message      |
     6    Message      |    Two files
     7    Message      |
     8    Listed     0 |M a.txt  +1 -1 (truncated)
     9    Listed     1 |M b.txt  +1 -1
    10    Message      |
    11 F  Meta         |diff --git a/a.txt b/a.txt
    12    Meta         |index 1111111..2222222 100644
    13    Meta         |--- a/a.txt
    14    Meta         |+++ b/a.txt
    15  @ Hunk         |@@ -1,3 +1,3 @@
    16    Removed      |-one
    17    Added        |+ONE
    18    Context      | two
    19    Context      | three
    20    Note         |... 1 more hunk (4 lines) not shown
    21 F  Meta         |diff --git a/b.txt b/b.txt
    22    Meta         |index 3333333..4444444 100644
    23    Meta         |--- a/b.txt
    24    Meta         |+++ b/b.txt
    25  @ Hunk         |@@ -1 +1 @@
    26    Removed      |-bee
    27    Added        |+BEE
    |}]
;;

let%expect_test "an uncommitted diff (no preamble), a commit without files: no list" =
  print_layout text;
  [%expect {|
     0 F  Meta         |diff --git a/a.txt b/a.txt
     1    Meta         |index 1111111..2222222 100644
     2    Meta         |--- a/a.txt
     3    Meta         |+++ b/a.txt
     4  @ Hunk         |@@ -1,3 +1,3 @@
     5    Removed      |-one
     6    Added        |+ONE
     7    Context      | two
     8    Context      | three
     9  @ Hunk         |@@ -10,2 +10,3 @@ nine
    10    Context      | ten
    11    Added        |+eleven
    12    Context      | twelve
    13    No_newline   |\ No newline at end of file
    14 F  Meta         |diff --git a/b.txt b/b.txt
    15    Meta         |index 3333333..4444444 100644
    16    Meta         |--- a/b.txt
    17    Meta         |+++ b/b.txt
    18  @ Hunk         |@@ -1 +1 @@
    19    Removed      |-bee
    20    Added        |+BEE
    |}];
  print_layout
    (Vcs_diff_text.of_diff
       { Diff.preamble = String.split_lines header @ [ "    Empty"; "" ]
       ; files = []
       ; cut = false
       });
  [%expect {|
    0    Preamble     |commit 43d2480ac115bf1972d7720a59c166d6d474175c
    1    Preamble     |Author:     Ches Test <ches-test@example.invalid>
    2    Preamble     |AuthorDate: 2026-01-01T00:00:00+00:00
    3    Preamble     |Commit:     Ches Test <ches-test@example.invalid>
    4    Preamble     |CommitDate: 2026-01-01T00:00:00+00:00
    5    Message      |
    6    Message      |    Empty
    7    Message      |
    |}]
;;

let%expect_test "offsets past the list shift; positions, spans and targets stay" =
  (* The same files without and with a preamble (so without and with a list). *)
  let plain = Vcs_diff_text.of_diff { renamed with preamble = [] } in
  let listed = Vcs_diff_text.of_diff renamed in
  let shift =
    String.substr_index_exn (Vcs_diff_text.text listed) ~pattern:"diff --git a/b.txt"
  in
  print_s
    [%sexp
      { shift : int
      ; plain_files = (Vcs_diff_text.file_starts plain : int list)
      ; listed_files = (Vcs_diff_text.file_starts listed : int list)
      ; plain_hunks = (Vcs_diff_text.hunk_starts plain : int list)
      ; listed_hunks = (Vcs_diff_text.hunk_starts listed : int list)
      }];
  [%expect {|
    ((shift 279) (plain_files (0 109)) (listed_files (279 388))
     (plain_hunks (81 257)) (listed_hunks (360 536)))
    |}];
  let shifted f = List.map (f plain) ~f:(fun offset -> offset + shift) in
  let same_starts f = List.equal Int.equal (shifted f) (f listed) in
  assert (same_starts Vcs_diff_text.file_starts);
  assert (same_starts Vcs_diff_text.hunk_starts);
  (* file_starts are start_of's file starts. *)
  List.iteri (Vcs_diff_text.file_starts listed) ~f:(fun file offset ->
    let start = Vcs_diff_text.start_of listed ~file ~hunk:None in
    assert (Option.equal Int.equal (Some offset) start));
  let length = String.length (Vcs_diff_text.text plain) in
  for offset = 0 to length - 1 do
    let same equal f = equal (f plain offset) (f listed (offset + shift)) in
    assert (same (Option.equal Vcs_diff_text.Position.equal) Vcs_diff_text.position_at);
    assert (
      same (Option.equal Vcs_diff_text.Kind.equal) (fun t offset ->
        Option.map (Vcs_diff_text.line_at t offset) ~f:(fun line -> line.kind)));
    assert (
      same (Option.equal Vcs_diff_text.Target.equal) (fun t offset ->
        Option.bind (Vcs_diff_text.line_at t offset) ~f:(fun line -> line.target)));
    assert (Option.is_none (Vcs_diff_text.listed_file_at plain offset));
    for stop = offset to Int.min length (offset + 40) do
      let span t start = Vcs_diff_text.span t ~start ~stop:(stop - offset + start) in
      assert (same (Result.equal (Option.equal Vcs_diff_text.Span.equal) Poly.equal) span)
    done
  done;
  (* Each Listed line names its own file (the layouts above show no other line does). *)
  List.iteri (Vcs_diff_text.file_starts listed) ~f:(fun file _ ->
    let offset =
      String.substr_index_exn
        (Vcs_diff_text.text listed)
        ~pattern:(if file = 0 then "M b.txt" else "R new.txt")
    in
    printf
      "file %d: %s\n"
      file
      (Sexp.to_string
         [%sexp (Vcs_diff_text.listed_file_at listed (offset + 3) : int option)]));
  [%expect {|
    file 0: (0)
    file 1: (1)
    |}]
;;
