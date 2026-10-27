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
