(* Pure tests of Patch over diffs parsed by Diff_output (literal git 2.43 output). Patches
   print verbatim, one line per patch line between bars; whether git applies them is
   tested in test_plan.ml. *)

open! Core
open Ches_vcs
open Ches_vcs_git

let files text = (ok_exn (Diff_output.parse Diff.Limits.default ~cut:false text)).files

let print_patch ?(reverse = false) file ~hunk =
  match Patch.hunk file ~hunk Whole ~reverse with
  | Error error -> printf "error: %s\n" (Error.to_string_hum error)
  | Ok patch ->
    assert (String.is_suffix patch ~suffix:"\n");
    List.iter (String.split_lines patch) ~f:(fun line -> printf "|%s|\n" line)
;;

let print_each ?reverse text =
  List.iter (files text) ~f:(fun (file : Diff.File.t) ->
    printf "--- %S\n" (Diff.File.path file);
    print_patch ?reverse file ~hunk:0)
;;

let%expect_test "quote" =
  List.iter
    [ "a.txt"
    ; "x y.txt"
    ; "moved \195\169.txt"
    ; "tab\there"
    ; "q\"uote"
    ; "back\\slash"
    ; "new\nline"
    ; "bell\007 bs\b vt\011 ff\012 cr\r"
    ; "ctl\001\031 del\127"
    ; "dir/sub dir/f"
    ]
    ~f:(fun path -> printf "%s\n" (Patch.quote ~prefix:"a/" path));
  print_endline (Patch.quote ~prefix:"b/" "tab\there");
  [%expect
    {|
    a/a.txt
    a/x y.txt
    a/moved é.txt
    "a/tab\there"
    "a/q\"uote"
    "a/back\\slash"
    "a/new\nline"
    "a/bell\a bs\b vt\v ff\f cr\r"
    "a/ctl\001\037 del\177"
    a/dir/sub dir/f
    "b/tab\there"
    |}]
;;

let two_hunks =
  {|diff --git a/a.txt b/a.txt
index 1111111..2222222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
@@ -8,3 +8,4 @@ seven
 eight

 ten
+eleven
|}
;;

let%expect_test "a modified file: each hunk, reverse, out of range" =
  let file = List.hd_exn (files two_hunks) in
  print_patch file ~hunk:0;
  print_patch file ~hunk:1;
  [%expect
    {|
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -1,3 +1,3 @@|
    | one|
    |-two|
    |+TWO|
    | three|
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -8,3 +8,4 @@ seven|
    | eight|
    | |
    | ten|
    |+eleven|
    |}];
  (* A whole hunk reads the same either way: git reverses it. *)
  print_s
    [%sexp
      ([%equal: string Or_error.t]
         (Patch.hunk file ~hunk:1 Whole ~reverse:false)
         (Patch.hunk file ~hunk:1 Whole ~reverse:true)
       : bool)];
  print_patch file ~hunk:2;
  print_patch file ~hunk:(-1);
  [%expect
    {|
    true
    error: Hunk 3 of a.txt does not exist (it has 2)
    error: Hunk 0 of a.txt does not exist (it has 2)
    |}]
;;

let%expect_test "added and deleted files keep their mode lines; /dev/null sides" =
  print_each
    {|diff --git a/new.txt b/new.txt
new file mode 100755
index 0000000..3333333
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+hello
+world
diff --git a/old.txt b/old.txt
deleted file mode 100644
index 4444444..0000000
--- a/old.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone
|};
  [%expect
    {|
    --- "new.txt"
    |diff --git a/new.txt b/new.txt|
    |new file mode 100755|
    |--- /dev/null|
    |+++ b/new.txt|
    |@@ -0,0 +1,2 @@|
    |+hello|
    |+world|
    --- "old.txt"
    |diff --git a/old.txt b/old.txt|
    |deleted file mode 100644|
    |--- a/old.txt|
    |+++ /dev/null|
    |@@ -1 +0,0 @@|
    |-gone|
    |}]
;;

let%expect_test "a renamed or copied file's hunk is a change of the new path alone" =
  print_each
    {|diff --git a/move me.txt b/moved é.txt
similarity index 80%
rename from move me.txt
rename to moved é.txt
index 5555555..6666666 100755
--- a/move me.txt
+++ b/moved é.txt
@@ -1,2 +1,2 @@
 alpha
-beta
+BETA
diff --git a/src.txt b/copy.txt
similarity index 90%
copy from src.txt
copy to copy.txt
index 7777777..8888888 100644
--- a/src.txt
+++ b/copy.txt
@@ -1 +1,2 @@
 x
+y
|};
  [%expect
    {|
    --- "moved \195\169.txt"
    |diff --git a/moved é.txt b/moved é.txt|
    |--- a/moved é.txt|
    |+++ b/moved é.txt|
    |@@ -1,2 +1,2 @@|
    | alpha|
    |-beta|
    |+BETA|
    --- "copy.txt"
    |diff --git a/copy.txt b/copy.txt|
    |--- a/copy.txt|
    |+++ b/copy.txt|
    |@@ -1 +1,2 @@|
    | x|
    |+y|
    |}]
;;

let%expect_test "odd names: spaces (git's trailing tab dropped), quoted names" =
  print_each
    "diff --git a/x y.txt b/x y.txt\n\
     index 1111111..2222222 100644\n\
     --- a/x y.txt\t\n\
     +++ b/x y.txt\t\n\
     @@ -1 +1 @@\n\
     -a\n\
     +b\n\
     diff --git \"a/tab\\there\" \"b/tab\\there\"\n\
     new file mode 100644\n\
     index 0000000..2222222\n\
     --- /dev/null\n\
     +++ \"b/tab\\there\"\n\
     @@ -0,0 +1 @@\n\
     +b\n\
     diff --git \"a/q\\\"uote \\\\ \\001\" \"b/q\\\"uote \\\\ \\001\"\n\
     deleted file mode 100644\n\
     index 2222222..0000000\n\
     --- \"a/q\\\"uote \\\\ \\001\"\n\
     +++ /dev/null\n\
     @@ -1 +0,0 @@\n\
     -b\n";
  [%expect
    {|
    --- "x y.txt"
    |diff --git a/x y.txt b/x y.txt|
    |--- a/x y.txt|
    |+++ b/x y.txt|
    |@@ -1 +1 @@|
    |-a|
    |+b|
    --- "tab\there"
    |diff --git "a/tab\there" "b/tab\there"|
    |new file mode 100644|
    |--- /dev/null|
    |+++ "b/tab\there"|
    |@@ -0,0 +1 @@|
    |+b|
    --- "q\"uote \\ \001"
    |diff --git "a/q\"uote \\ \001" "b/q\"uote \\ \001"|
    |deleted file mode 100644|
    |--- "a/q\"uote \\ \001"|
    |+++ /dev/null|
    |@@ -1 +0,0 @@|
    |-b|
    |}]
;;

let%expect_test "no newline at end of file, on either side; CRLF; empty context" =
  print_each
    "diff --git a/nonl.txt b/nonl.txt\n\
     index 1111111..2222222 100644\n\
     --- a/nonl.txt\n\
     +++ b/nonl.txt\n\
     @@ -1 +1,2 @@\n\
     -last\n\
     \\ No newline at end of file\n\
     +last\n\
     +more\n\
     \\ No newline at end of file\n\
     diff --git a/crlf.txt b/crlf.txt\n\
     index 1111111..2222222 100644\n\
     --- a/crlf.txt\n\
     +++ b/crlf.txt\n\
     @@ -1,3 +1,3 @@\n\
    \ a\r\n\
     -b\r\n\
     +B\r\n\n\
     diff --git a/fixed.txt b/fixed.txt\n\
     index 1111111..2222222 100644\n\
     --- a/fixed.txt\n\
     +++ b/fixed.txt\n\
     @@ -1 +1 @@\n\
     -end\n\
     \\ No newline at end of file\n\
     +end\n";
  [%expect
    {|
    --- "nonl.txt"
    |diff --git a/nonl.txt b/nonl.txt|
    |--- a/nonl.txt|
    |+++ b/nonl.txt|
    |@@ -1 +1,2 @@|
    |-last|
    |\ No newline at end of file|
    |+last|
    |+more|
    |\ No newline at end of file|
    --- "crlf.txt"
    |diff --git a/crlf.txt b/crlf.txt|
    |--- a/crlf.txt|
    |+++ b/crlf.txt|
    |@@ -1,3 +1,3 @@|
    | a|
    |-b|
    |+B|
    | |
    --- "fixed.txt"
    |diff --git a/fixed.txt b/fixed.txt|
    |--- a/fixed.txt|
    |+++ b/fixed.txt|
    |@@ -1 +1 @@|
    |-end|
    |\ No newline at end of file|
    |+end|
    |}];
  (* The carriage returns are kept (split_lines above hides them). *)
  let crlf =
    List.hd_exn (files "diff --git a/c b/c\n--- a/c\n+++ b/c\n@@ -1 +1 @@\n-b\r\n+B\r\n")
  in
  printf "%S\n" (ok_exn (Patch.hunk crlf ~hunk:0 Whole ~reverse:false));
  [%expect {| "diff --git a/c b/c\n--- a/c\n+++ b/c\n@@ -1 +1 @@\n-b\r\n+B\r\n" |}]
;;

let%expect_test "files without line actions, type changes and missing modes are errors" =
  print_each
    {|diff --git a/bin.dat b/bin.dat
index 1111111..2222222 100644
Binary files a/bin.dat and b/bin.dat differ
diff --git a/mode.sh b/mode.sh
old mode 100644
new mode 100755
diff --git a/old name b/new name
similarity index 100%
rename from old name
rename to new name
diff --git a/src b/copy
similarity index 100%
copy from src
copy to copy
diff --git a/sub b/sub
index 1111111..2222222 160000
--- a/sub
+++ b/sub
@@ -1 +1 @@
-Subproject commit 1111111111111111111111111111111111111111
+Subproject commit 2222222222222222222222222222222222222222
diff --cc both.txt
index 1111111,2222222..0000000
--- a/both.txt
+++ b/both.txt
@@@ -1,1 -1,1 +1,5 @@@
++<<<<<<< HEAD
 +ours
++=======
+ theirs
++>>>>>>> other
* Unmerged path gone.txt
diff --git a/link b/link
old mode 100644
new mode 120000
index 1111111..2222222
--- a/link
+++ b/link
@@ -1 +1 @@
-text
+target
\ No newline at end of file
|};
  [%expect
    {|
    --- "bin.dat"
    error: Hunk actions do not apply to bin.dat: it is binary
    --- "mode.sh"
    error: Hunk actions do not apply to mode.sh: only its mode changed
    --- "new name"
    error: Hunk actions do not apply to new name: it is only renamed
    --- "copy"
    error: Hunk actions do not apply to copy: it is only copied
    --- "sub"
    error: Hunk actions do not apply to sub: it is a submodule
    --- "both.txt"
    error: Hunk actions do not apply to both.txt: it is conflicted
    --- "gone.txt"
    error: Hunk actions do not apply to gone.txt: it is conflicted
    --- "link"
    error: Hunk actions do not apply to link: its type changed
    |}];
  (* Headers without the mode lines a new or deleted file needs (not something git writes;
     built by hand). *)
  let file = List.hd_exn (files two_hunks) in
  print_patch { file with change = Added; old_path = None; new_mode = None } ~hunk:0;
  print_patch { file with change = Deleted; new_path = None; old_mode = None } ~hunk:0;
  [%expect
    {|
    error: a.txt is new but its diff names no mode
    error: a.txt is deleted but its diff names no mode
    |}]
;;

(* Phase 4: line selections and patches of several hunks. *)

let print_lines ?(reverse = false) file selections =
  match Patch.hunks file selections ~reverse with
  | Error error -> printf "error: %s\n" (Error.to_string_hum error)
  | Ok patch ->
    assert (String.is_suffix patch ~suffix:"\n");
    List.iter (String.split_lines patch) ~f:(fun line -> printf "|%s|\n" line)
;;

let lines indices = Patch.Selection.Lines indices

let%expect_test "selection counts and changes" =
  let file = List.hd_exn (files two_hunks) in
  let hunk = List.hd_exn file.hunks in
  List.iter
    [ Patch.Selection.Whole
    ; lines []
    ; lines [ 0; 3 ]
    ; lines [ 1 ]
    ; lines [ 2; 1; 2 ]
    ; lines [ 9 ]
    ]
    ~f:(fun selection ->
      printf
        "%s: %d\n"
        (Sexp.to_string [%sexp (selection : Patch.Selection.t)])
        (Patch.Selection.changes hunk selection));
  List.iter
    [ []
    ; [ 0, lines [ 0; 3 ] ]
    ; [ 0, lines [ 1 ]; 1, Patch.Selection.Whole ]
    ; [ 1, Whole; 0, Whole ]
    ; [ 0, Whole; 0, Whole ]
    ; [ 2, Whole ]
    ; [ 0, lines [ 4 ] ]
    ; [ 1, lines [ -1 ] ]
    ]
    ~f:(fun selections ->
      match Patch.changes file selections with
      | Ok n -> printf "%d\n" n
      | Error error -> printf "error: %s\n" (Error.to_string_hum error));
  [%expect
    {|
    Whole: 2
    (Lines()): 0
    (Lines(0 3)): 0
    (Lines(1)): 1
    (Lines(2 1 2)): 2
    (Lines(9)): 0
    0
    0
    2
    error: Hunks of a.txt must be listed once each, in order
    error: Hunks of a.txt must be listed once each, in order
    error: Hunk 3 of a.txt does not exist (it has 2)
    error: Line 5 of hunk 1/2 of a.txt does not exist (it has 4)
    error: Line 0 of hunk 2/2 of a.txt does not exist (it has 4)
    |}]
;;

let%expect_test "lines of one hunk, forward and reverse" =
  let file = List.hd_exn (files two_hunks) in
  (* Hunk 1: " one" (0), "-two" (1), "+TWO" (2), " three" (3). *)
  print_endline "-- only context: nothing";
  print_lines file [ 0, lines [ 0; 3 ] ];
  print_endline "-- forward, only the +: the - stays as context";
  print_lines file [ 0, lines [ 2 ] ];
  print_endline "-- forward, only the -: the + is dropped";
  print_lines file [ 0, lines [ 1 ] ];
  print_endline "-- reverse, only the +: the - is dropped";
  print_lines ~reverse:true file [ 0, lines [ 2 ] ];
  print_endline "-- reverse, only the -: the + stays as context";
  print_lines ~reverse:true file [ 0, lines [ 1 ] ];
  print_endline "-- every change, with context: the hunk itself";
  print_lines file [ 0, lines [ 0; 1; 2; 3 ] ];
  print_endline "-- Patch.hunk of a Lines selection";
  print_patch file ~hunk:1;
  (* Patch.hunk of a Lines selection is Patch.hunks of that hunk. *)
  print_s
    [%sexp
      ([%equal: string Or_error.t]
         (Patch.hunk file ~hunk:1 (lines [ 3 ]) ~reverse:false)
         (Patch.hunks file [ 1, lines [ 3 ] ] ~reverse:false)
       : bool)];
  [%expect
    {|
    -- only context: nothing
    error: No changes selected in a.txt
    -- forward, only the +: the - stays as context
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -1,3 +1,4 @@|
    | one|
    | two|
    |+TWO|
    | three|
    -- forward, only the -: the + is dropped
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -1,3 +1,2 @@|
    | one|
    |-two|
    | three|
    -- reverse, only the +: the - is dropped
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -1,2 +1,3 @@|
    | one|
    |+TWO|
    | three|
    -- reverse, only the -: the + stays as context
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -1,4 +1,3 @@|
    | one|
    |-two|
    | TWO|
    | three|
    -- every change, with context: the hunk itself
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -1,3 +1,3 @@|
    | one|
    |-two|
    |+TWO|
    | three|
    -- Patch.hunk of a Lines selection
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -8,3 +8,4 @@ seven|
    | eight|
    | |
    | ten|
    |+eleven|
    true
    |}]
;;

let%expect_test "several hunks: one patch, headers shifted by the earlier hunks" =
  let file = List.hd_exn (files two_hunks) in
  print_endline
    "-- forward: hunk 1 loses a line, so hunk 2's new side starts a line earlier";
  print_lines file [ 0, lines [ 1 ]; 1, Whole ];
  print_endline "-- reverse: the old side is the shifted one";
  print_lines ~reverse:true file [ 0, lines [ 2 ]; 1, lines [ 3 ] ];
  print_endline "-- a hunk with no selected change is left out (no shift from it)";
  print_lines file [ 0, lines [ 0 ]; 1, lines [ 3 ] ];
  print_endline "-- whole hunks through hunks: verbatim lines, header recomputed alike";
  print_lines file [ 0, Whole; 1, Whole ];
  [%expect
    {|
    -- forward: hunk 1 loses a line, so hunk 2's new side starts a line earlier
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -1,3 +1,2 @@|
    | one|
    |-two|
    | three|
    |@@ -8,3 +7,4 @@ seven|
    | eight|
    | |
    | ten|
    |+eleven|
    -- reverse: the old side is the shifted one
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -1,2 +1,3 @@|
    | one|
    |+TWO|
    | three|
    |@@ -7,3 +8,4 @@ seven|
    | eight|
    | |
    | ten|
    |+eleven|
    -- a hunk with no selected change is left out (no shift from it)
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -8,3 +8,4 @@ seven|
    | eight|
    | |
    | ten|
    |+eleven|
    -- whole hunks through hunks: verbatim lines, header recomputed alike
    |diff --git a/a.txt b/a.txt|
    |--- a/a.txt|
    |+++ b/a.txt|
    |@@ -1,3 +1,3 @@|
    | one|
    |-two|
    |+TWO|
    | three|
    |@@ -8,3 +8,4 @@ seven|
    | eight|
    | |
    | ten|
    |+eleven|
    |}]
;;

(* Adjacent hunks (git merges hunks closer than twice the context, so these are as close
   as two hunks get), the first and last lines of a hunk being changes, an insertion hunk
   (old count 0, its start the line before) and a removal to an empty new side. *)
let%expect_test "adjacent hunks; changes on a hunk's first and last lines; empty sides" =
  let file =
    List.hd_exn
      (files
         {|diff --git a/b.txt b/b.txt
--- a/b.txt
+++ b/b.txt
@@ -1,4 +1,5 @@
-a
+A
+A2
 b
 c
 d
@@ -11,4 +12,3 @@ j
 k
 l
 m
-n
@@ -20,0 +21,2 @@ s
+t
+u
|})
  in
  print_endline "-- forward: first line of hunk 1, last of hunk 2, one of the insertion";
  print_lines file [ 0, lines [ 0 ]; 1, lines [ 3 ]; 2, lines [ 1 ] ];
  print_endline "-- forward: the second added line only, then all of hunk 2";
  print_lines file [ 0, lines [ 2 ]; 1, Whole; 2, Whole ];
  print_endline "-- reverse: the insertion's first line (its old side stays empty)";
  print_lines ~reverse:true file [ 0, lines [ 1; 2 ]; 2, lines [ 0 ] ];
  [%expect
    {|
    -- forward: first line of hunk 1, last of hunk 2, one of the insertion
    |diff --git a/b.txt b/b.txt|
    |--- a/b.txt|
    |+++ b/b.txt|
    |@@ -1,4 +1,3 @@|
    |-a|
    | b|
    | c|
    | d|
    |@@ -11,4 +10,3 @@ j|
    | k|
    | l|
    | m|
    |-n|
    |@@ -20,0 +19,1 @@ s|
    |+u|
    -- forward: the second added line only, then all of hunk 2
    |diff --git a/b.txt b/b.txt|
    |--- a/b.txt|
    |+++ b/b.txt|
    |@@ -1,4 +1,5 @@|
    | a|
    |+A2|
    | b|
    | c|
    | d|
    |@@ -11,4 +12,3 @@ j|
    | k|
    | l|
    | m|
    |-n|
    |@@ -20,0 +21,2 @@ s|
    |+t|
    |+u|
    -- reverse: the insertion's first line (its old side stays empty)
    |diff --git a/b.txt b/b.txt|
    |--- a/b.txt|
    |+++ b/b.txt|
    |@@ -1,3 +1,5 @@|
    |+A|
    |+A2|
    | b|
    | c|
    | d|
    |@@ -19,1 +21,2 @@ s|
    |+t|
    | u|
    |}]
;;

let%expect_test "no newline at end of file: whichever line ends each side" =
  (* nonl.txt: "-last" (0), marker (1), "+last" (2), "+more" (3), marker (4): the old side
     ends in "last" and the new in "more", both without a newline. *)
  let nonl, fixed =
    match
      files
        "diff --git a/nonl.txt b/nonl.txt\n\
         --- a/nonl.txt\n\
         +++ b/nonl.txt\n\
         @@ -1 +1,2 @@\n\
         -last\n\
         \\ No newline at end of file\n\
         +last\n\
         +more\n\
         \\ No newline at end of file\n\
         diff --git a/fixed.txt b/fixed.txt\n\
         --- a/fixed.txt\n\
         +++ b/fixed.txt\n\
         @@ -1,2 +1,2 @@\n\
        \ start\n\
         -end\n\
         \\ No newline at end of file\n\
         +end\n"
    with
    | [ nonl; fixed ] -> nonl, fixed
    | _ -> assert false
  in
  print_endline "-- forward, +more: the kept old last line now ends in a newline";
  print_lines nonl [ 0, lines [ 3 ] ];
  print_endline "-- forward, +more and its marker selected too: the same";
  print_lines nonl [ 0, lines [ 3; 4 ] ];
  print_endline "-- forward, -last: the new side is empty";
  print_lines nonl [ 0, lines [ 0 ] ];
  print_endline "-- forward, +last: the kept line gains a newline, the added one has it";
  print_lines nonl [ 0, lines [ 2 ] ];
  print_endline "-- forward, -last and +more: the new side ends in more, no newline";
  print_lines nonl [ 0, lines [ 0; 3 ] ];
  print_endline "-- reverse, +more: last stays, with its newline, on both sides";
  print_lines ~reverse:true nonl [ 0, lines [ 3 ] ];
  print_endline "-- reverse, +last: more stays last without a newline on both sides";
  print_lines ~reverse:true nonl [ 0, lines [ 2 ] ];
  print_endline "-- reverse, -last: restored before the kept lines, so with a newline";
  print_lines ~reverse:true nonl [ 0, lines [ 0 ] ];
  print_endline "-- fixed.txt forward, +end: a second end after the kept one";
  print_lines fixed [ 0, lines [ 3 ] ];
  print_endline "-- fixed.txt forward, -end: the file ends in start (with its newline)";
  print_lines fixed [ 0, lines [ 1 ] ];
  print_endline
    "-- fixed.txt reverse, -end: restored before the kept end, so with a newline";
  print_lines ~reverse:true fixed [ 0, lines [ 1 ] ];
  [%expect
    {|
    -- forward, +more: the kept old last line now ends in a newline
    |diff --git a/nonl.txt b/nonl.txt|
    |--- a/nonl.txt|
    |+++ b/nonl.txt|
    |@@ -1,1 +1,2 @@|
    |-last|
    |\ No newline at end of file|
    |+last|
    |+more|
    |\ No newline at end of file|
    -- forward, +more and its marker selected too: the same
    |diff --git a/nonl.txt b/nonl.txt|
    |--- a/nonl.txt|
    |+++ b/nonl.txt|
    |@@ -1,1 +1,2 @@|
    |-last|
    |\ No newline at end of file|
    |+last|
    |+more|
    |\ No newline at end of file|
    -- forward, -last: the new side is empty
    |diff --git a/nonl.txt b/nonl.txt|
    |--- a/nonl.txt|
    |+++ b/nonl.txt|
    |@@ -1,1 +0,0 @@|
    |-last|
    |\ No newline at end of file|
    -- forward, +last: the kept line gains a newline, the added one has it
    |diff --git a/nonl.txt b/nonl.txt|
    |--- a/nonl.txt|
    |+++ b/nonl.txt|
    |@@ -1,1 +1,2 @@|
    |-last|
    |\ No newline at end of file|
    |+last|
    |+last|
    -- forward, -last and +more: the new side ends in more, no newline
    |diff --git a/nonl.txt b/nonl.txt|
    |--- a/nonl.txt|
    |+++ b/nonl.txt|
    |@@ -1,1 +1,1 @@|
    |-last|
    |\ No newline at end of file|
    |+more|
    |\ No newline at end of file|
    -- reverse, +more: last stays, with its newline, on both sides
    |diff --git a/nonl.txt b/nonl.txt|
    |--- a/nonl.txt|
    |+++ b/nonl.txt|
    |@@ -1,1 +1,2 @@|
    | last|
    |+more|
    |\ No newline at end of file|
    -- reverse, +last: more stays last without a newline on both sides
    |diff --git a/nonl.txt b/nonl.txt|
    |--- a/nonl.txt|
    |+++ b/nonl.txt|
    |@@ -1,1 +1,2 @@|
    |+last|
    | more|
    |\ No newline at end of file|
    -- reverse, -last: restored before the kept lines, so with a newline
    |diff --git a/nonl.txt b/nonl.txt|
    |--- a/nonl.txt|
    |+++ b/nonl.txt|
    |@@ -1,3 +1,2 @@|
    |-last|
    | last|
    | more|
    |\ No newline at end of file|
    -- fixed.txt forward, +end: a second end after the kept one
    |diff --git a/fixed.txt b/fixed.txt|
    |--- a/fixed.txt|
    |+++ b/fixed.txt|
    |@@ -1,2 +1,3 @@|
    | start|
    |-end|
    |\ No newline at end of file|
    |+end|
    |+end|
    -- fixed.txt forward, -end: the file ends in start (with its newline)
    |diff --git a/fixed.txt b/fixed.txt|
    |--- a/fixed.txt|
    |+++ b/fixed.txt|
    |@@ -1,2 +1,1 @@|
    | start|
    |-end|
    |\ No newline at end of file|
    -- fixed.txt reverse, -end: restored before the kept end, so with a newline
    |diff --git a/fixed.txt b/fixed.txt|
    |--- a/fixed.txt|
    |+++ b/fixed.txt|
    |@@ -1,3 +1,2 @@|
    | start|
    |-end|
    | end|
    |}]
;;

let%expect_test "CRLF lines keep their carriage returns" =
  let file =
    List.hd_exn
      (files "diff --git a/c b/c\n--- a/c\n+++ b/c\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n")
  in
  List.iter [ false; true ] ~f:(fun reverse ->
    printf "%S\n" (ok_exn (Patch.hunks file [ 0, lines [ 2 ] ] ~reverse)));
  [%expect
    {|
    "diff --git a/c b/c\n--- a/c\n+++ b/c\n@@ -1,2 +1,3 @@\n a\r\n b\r\n+B\r\n"
    "diff --git a/c b/c\n--- a/c\n+++ b/c\n@@ -1,1 +1,2 @@\n a\r\n+B\r\n"
    |}]
;;

let%expect_test "added and deleted files: created or removed only from an empty side" =
  let added, deleted =
    match
      files
        {|diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,3 @@
+one
+two
+three
diff --git a/old.txt b/old.txt
deleted file mode 100755
--- a/old.txt
+++ /dev/null
@@ -1,3 +0,0 @@
-one
-two
-three
|}
    with
    | [ added; deleted ] -> added, deleted
    | _ -> assert false
  in
  print_endline "-- stage 2 of 3 lines of a new (intent-to-add) file: still a creation";
  print_lines added [ 0, lines [ 0; 2 ] ];
  print_endline "-- unstage 2 of 3: the file stays with the third (a modification)";
  print_lines ~reverse:true added [ 0, lines [ 0; 2 ] ];
  print_endline "-- unstage every line: the file goes";
  print_lines ~reverse:true added [ 0, lines [ 0; 1; 2 ] ];
  print_endline "-- stage 1 of 3 lines of a deletion: the file stays with two";
  print_lines deleted [ 0, lines [ 1 ] ];
  print_endline "-- stage every line: the deletion";
  print_lines deleted [ 0, lines [ 0; 1; 2 ] ];
  print_endline "-- unstage 1 of 3 of a staged deletion: the file returns with that line";
  print_lines ~reverse:true deleted [ 0, lines [ 1 ] ];
  [%expect
    {|
    -- stage 2 of 3 lines of a new (intent-to-add) file: still a creation
    |diff --git a/new.txt b/new.txt|
    |new file mode 100644|
    |--- /dev/null|
    |+++ b/new.txt|
    |@@ -0,0 +1,2 @@|
    |+one|
    |+three|
    -- unstage 2 of 3: the file stays with the third (a modification)
    |diff --git a/new.txt b/new.txt|
    |--- a/new.txt|
    |+++ b/new.txt|
    |@@ -1,1 +1,3 @@|
    |+one|
    | two|
    |+three|
    -- unstage every line: the file goes
    |diff --git a/new.txt b/new.txt|
    |new file mode 100644|
    |--- /dev/null|
    |+++ b/new.txt|
    |@@ -0,0 +1,3 @@|
    |+one|
    |+two|
    |+three|
    -- stage 1 of 3 lines of a deletion: the file stays with two
    |diff --git a/old.txt b/old.txt|
    |--- a/old.txt|
    |+++ b/old.txt|
    |@@ -1,3 +1,2 @@|
    | one|
    |-two|
    | three|
    -- stage every line: the deletion
    |diff --git a/old.txt b/old.txt|
    |deleted file mode 100755|
    |--- a/old.txt|
    |+++ /dev/null|
    |@@ -1,3 +0,0 @@|
    |-one|
    |-two|
    |-three|
    -- unstage 1 of 3 of a staged deletion: the file returns with that line
    |diff --git a/old.txt b/old.txt|
    |deleted file mode 100755|
    |--- a/old.txt|
    |+++ /dev/null|
    |@@ -1,1 +0,0 @@|
    |-two|
    |}]
;;

(* Type changes are refused by the same check as hunks (tested above). *)
let%expect_test "line actions: files without them, renames, indices out of range" =
  List.iter
    (files
       {|diff --git a/bin.dat b/bin.dat
index 1111111..2222222 100644
Binary files a/bin.dat and b/bin.dat differ
diff --git a/old name.txt b/new name.txt
similarity index 80%
rename from old name.txt
rename to new name.txt
--- a/old name.txt
+++ b/new name.txt
@@ -1,2 +1,2 @@
 keep
-x
+y
diff --git a/link b/link
deleted file mode 100644
--- a/link
+++ /dev/null
@@ -1 +0,0 @@
-text
diff --git a/link b/link
new file mode 120000
--- /dev/null
+++ b/link
@@ -0,0 +1 @@
+target
\ No newline at end of file
|})
    ~f:(fun (file : Diff.File.t) ->
      printf "--- %S\n" (Diff.File.path file);
      print_lines file [ 0, lines [ 1 ] ];
      match Patch.changes file [] with
      | Ok n -> printf "changes of []: %d\n" n
      | Error error -> printf "changes of []: %s\n" (Error.to_string_hum error));
  [%expect
    {|
    --- "bin.dat"
    error: Line actions do not apply to bin.dat: it is binary
    changes of []: Line actions do not apply to bin.dat: it is binary
    --- "new name.txt"
    |diff --git a/new name.txt b/new name.txt|
    |--- a/new name.txt|
    |+++ b/new name.txt|
    |@@ -1,2 +1,1 @@|
    | keep|
    |-x|
    changes of []: 0
    --- "link"
    error: Line 2 of hunk 1/1 of link does not exist (it has 1)
    changes of []: 0
    --- "link"
    error: No changes selected in link
    changes of []: 0
    |}]
;;
