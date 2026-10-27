(* Pure tests of Diff_output over literal captured patch output (git 2.43). *)

open! Core
open Ches_vcs
open Ches_vcs_git

let parse ?(limits = Diff.Limits.default) ?(cut = false) ?header text =
  Show.or_error (Show.diff ?header) (Diff_output.parse limits ~cut text)
;;

let%expect_test "Diff_output.command and ok_exits for each source" =
  List.iter
    [ Diff_output.Source.Worktree { paths = [] }
    ; Worktree { paths = [ "-a"; "b c" ] }
    ; Index { paths = [ "old"; "new" ] }
    ; Untracked "dir/new file"
    ; Commit "a757577ac7f79aa5fd48614f00553a6319b37a4a"
    ]
    ~f:(fun source ->
      let spec = Diff_output.command ~cwd:"/w" source in
      print_s
        [%sexp
          (List.drop (Exec.Spec.argv spec) 6 : string list)
          , (Diff_output.ok_exits source : int list)
          , (spec.kind : Exec.Kind.t)]);
  [%expect
    {|
    ((diff --no-color --no-ext-diff --no-relative --src-prefix=a/ --dst-prefix=b/
      --find-renames --submodule=short --)
     (0) Read)
    ((diff --no-color --no-ext-diff --no-relative --src-prefix=a/ --dst-prefix=b/
      --find-renames --submodule=short -- -a "b c")
     (0) Read)
    ((diff --cached --no-color --no-ext-diff --no-relative --src-prefix=a/
      --dst-prefix=b/ --find-renames --submodule=short -- old new)
     (0) Read)
    ((diff --no-index --no-color --no-ext-diff --no-relative --src-prefix=a/
      --dst-prefix=b/ --find-renames --submodule=short -- /dev/null
      "dir/new file")
     (0 1) Read)
    ((show --no-color --no-ext-diff --no-relative --src-prefix=a/ --dst-prefix=b/
      --find-renames --submodule=short --no-show-signature --format=fuller
      --date=iso-strict --end-of-options a757577ac7f79aa5fd48614f00553a6319b37a4a
      --)
     (0) Read)
    |}]
;;

let%expect_test "an empty diff" =
  parse "";
  [%expect {| |}]
;;

let worktree_diff =
  {|diff --git a/a.txt b/a.txt
index f893115..be0cc06 100644
--- a/a.txt
+++ b/a.txt
@@ -5,3 +5,4 @@ four
 five
 six
 seven
+eight
diff --git a/bin.dat b/bin.dat
index 8352675..1592e5c 100644
Binary files a/bin.dat and b/bin.dat differ
diff --git a/mode.sh b/mode.sh
old mode 100755
new mode 100644
diff --git a/nonl.txt b/nonl.txt
index 1c1206e..a9ebee0 100644
--- a/nonl.txt
+++ b/nonl.txt
@@ -1 +1,2 @@
-last
\ No newline at end of file
+last
+more
\ No newline at end of file
|}
;;

let%expect_test "modified, binary, mode-only, no newline at end of file" =
  parse ~header:true worktree_diff;
  [%expect
    {|
    file "a.txt" -> "a.txt" Modified modes 100644..100644
      header |diff --git a/a.txt b/a.txt
      header |index f893115..be0cc06 100644
      header |--- a/a.txt
      header |+++ b/a.txt
      @@ -5,3 +5,4 @@ four  [-5,3 +5,4] section="four"
        ctx   5   5 " "  "five"
        ctx   6   6 " "  "six"
        ctx   7   7 " "  "seven"
        add   .   8 "+"  "eight"
    file "bin.dat" -> "bin.dat" Modified modes 100644..100644 binary no-line-actions
      header |diff --git a/bin.dat b/bin.dat
      header |index 8352675..1592e5c 100644
      header |Binary files a/bin.dat and b/bin.dat differ
    file "mode.sh" -> "mode.sh" Modified modes 100755..100644 mode-only no-line-actions
      header |diff --git a/mode.sh b/mode.sh
      header |old mode 100755
      header |new mode 100644
    file "nonl.txt" -> "nonl.txt" Modified modes 100644..100644
      header |diff --git a/nonl.txt b/nonl.txt
      header |index 1c1206e..a9ebee0 100644
      header |--- a/nonl.txt
      header |+++ b/nonl.txt
      @@ -1 +1,2 @@  [-1,1 +1,2] section=""
        del   1   . "-"  "last"
        eof   .   . "\\" " No newline at end of file"
        add   .   1 "+"  "last"
        add   .   2 "+"  "more"
        eof   .   . "\\" " No newline at end of file"
    |}]
;;

let%expect_test "deleted, rename-only, new empty file, added CRLF lines, spaces and \
                 unicode in names"
  =
  parse
    "diff --git a/del.txt b/del.txt\n\
     deleted file mode 100644\n\
     index 286c5f5..0000000\n\
     --- a/del.txt\n\
     +++ /dev/null\n\
     @@ -1 +0,0 @@\n\
     -gone\n\
     diff --git a/move me.txt b/moved \195\169.txt\n\
     similarity index 100%\n\
     rename from move me.txt\n\
     rename to moved \195\169.txt\n\
     diff --git a/empty b/empty\n\
     new file mode 100644\n\
     index 0000000..e69de29\n\
     diff --git a/new file.txt b/new file.txt\n\
     new file mode 100644\n\
     index 0000000..23eb407\n\
     --- /dev/null\n\
     +++ b/new file.txt\t\n\
     @@ -0,0 +1,2 @@\n\
     +hello\r\n\
     +world\r\n\
     diff --git a/deleted empty b/deleted empty\n\
     deleted file mode 100644\n\
     index e69de29..0000000\n";
  [%expect
    {|
    file "del.txt" -> - Deleted modes 100644..-
      @@ -1 +0,0 @@  [-1,1 +0,0] section=""
        del   1   . "-"  "gone"
    file "move me.txt" -> "moved \195\169.txt" (Renamed(similarity(100))) modes -..- rename-only no-line-actions
    file - -> "empty" Added modes -..100644
    file - -> "new file.txt" Added modes -..100644
      @@ -0,0 +1,2 @@  [-0,0 +1,2] section=""
        add   .   1 "+"  "hello\r"
        add   .   2 "+"  "world\r"
    file "deleted empty" -> - Deleted modes 100644..-
    |}]
;;

let%expect_test "rename and copy with changes, C-quoted names" =
  parse
    {|diff --git a/old name.txt "b/new\nname.txt"
similarity index 75%
rename from old name.txt
rename to "new\nname.txt"
index 1111111..2222222 100644
--- a/old name.txt
+++ "b/new\nname.txt"
@@ -1,2 +1,2 @@
 keep
-old
+new
diff --git "a/q\"uote.txt" "b/q\"uote.txt"
new file mode 100755
index 0000000..587be6b
--- /dev/null
+++ "b/q\"uote.txt"
@@ -0,0 +1 @@
+x
diff --git a/src.ml b/copy.ml
similarity index 90%
copy from src.ml
copy to copy.ml
index 3333333..4444444 100644
--- a/src.ml
+++ b/copy.ml
@@ -3 +3 @@ let f x =
-  x
+  x + 1
diff --git "a/tab\there\303\251" "b/tab\there\303\251"
new file mode 100644
index 0000000..e69de29
|};
  [%expect
    {|
    file "old name.txt" -> "new\nname.txt" (Renamed(similarity(75))) modes 100644..100644
      @@ -1,2 +1,2 @@  [-1,2 +1,2] section=""
        ctx   1   1 " "  "keep"
        del   2   . "-"  "old"
        add   .   2 "+"  "new"
    file - -> "q\"uote.txt" Added modes -..100755
      @@ -0,0 +1 @@  [-0,0 +1,1] section=""
        add   .   1 "+"  "x"
    file "src.ml" -> "copy.ml" (Copied(similarity(90))) modes 100644..100644
      @@ -3 +3 @@ let f x =  [-3,1 +3,1] section="let f x ="
        del   3   . "-"  "  x"
        add   .   3 "+"  "  x + 1"
    file - -> "tab\there\195\169" Added modes -..100644
    |}]
;;

let%expect_test "submodules (--submodule=short)" =
  parse
    {|diff --git a/sub b/sub
new file mode 160000
index 0000000..b308c3e
--- /dev/null
+++ b/sub
@@ -0,0 +1 @@
+Subproject commit b308c3e56c484d4daeb357bae251e8e8ac99b4ed
diff --git a/sub2 b/sub2
index b308c3e..5928c94 160000
--- a/sub2
+++ b/sub2
@@ -1 +1 @@
-Subproject commit b308c3e56c484d4daeb357bae251e8e8ac99b4ed
+Subproject commit 5928c94995a4d27bbdb81295224ad8258d35804c-dirty
|};
  [%expect
    {|
    file - -> "sub" Added modes -..160000 submodule no-line-actions
      @@ -0,0 +1 @@  [-0,0 +1,1] section=""
        add   .   1 "+"  "Subproject commit b308c3e56c484d4daeb357bae251e8e8ac99b4ed"
    file "sub2" -> "sub2" Modified modes 160000..160000 submodule no-line-actions
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "Subproject commit b308c3e56c484d4daeb357bae251e8e8ac99b4ed"
        add   .   1 "+"  "Subproject commit 5928c94995a4d27bbdb81295224ad8258d35804c-dirty"
    |}]
;;

let%expect_test "a conflicted work tree: combined diffs and unmerged paths" =
  parse
    {|diff --cc aa.txt
index b19a1e9,950b81b..0000000
--- a/aa.txt
+++ b/aa.txt
@@@ -1,1 -1,1 +1,5 @@@
++<<<<<<< HEAD
 +ours
++=======
+ theirs
++>>>>>>> other
* Unmerged path dd-main.txt
* Unmerged path du.txt
diff --cc uu.txt
index b19a1e9,950b81b..0000000
--- a/uu.txt
+++ b/uu.txt
@@@ -1,2 -1,2 +1,2 @@@ section
  same
- ours-only
 -theirs-only
++both
|};
  [%expect
    {|
    file "aa.txt" -> "aa.txt" Unmerged modes -..- combined no-line-actions
      @@@ -1,1 -1,1 +1,5 @@@  [-1,1 +1,5] section=""
        add   .   1 "++" "<<<<<<< HEAD"
        add   .   2 " +" "ours"
        add   .   3 "++" "======="
        add   .   4 "+ " "theirs"
        add   .   5 "++" ">>>>>>> other"
    file "dd-main.txt" -> "dd-main.txt" Unmerged modes -..- no-line-actions
    file "du.txt" -> "du.txt" Unmerged modes -..- no-line-actions
    file "uu.txt" -> "uu.txt" Unmerged modes -..- combined no-line-actions
      @@@ -1,2 -1,2 +1,2 @@@ section  [-1,2 +1,2] section="section"
        ctx   .   1 "  " "same"
        del   .   . "- " "ours-only"
        del   .   . " -" "theirs-only"
        add   .   2 "++" "both"
    |}]
;;

let%expect_test "show: a commit's header and message, then its diff; a merge" =
  parse
    {|commit a757577ac7f79aa5fd48614f00553a6319b37a4a
Author:     Ches Test <ches-test@example.invalid>
AuthorDate: 2026-01-01T00:00:00+00:00
Commit:     Ches Test <ches-test@example.invalid>
CommitDate: 2026-01-01T00:00:00+00:00

    Second

    diff --git a/in/the b/message
diff --git a/a.txt b/a.txt
index 2019eda..be0cc06 100644
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,2 @@
 one
-two
+TWO
|};
  parse
    {|commit fccb9f23e86da95d1fc3cbe2e744fff3ee40e500
Merge: 90c5cb5 4e98047
Author:     Ches Test <ches-test@example.invalid>

    merge
|};
  parse
    {|commit fccb9f23e86da95d1fc3cbe2e744fff3ee40e500
Merge: 90c5cb5 4e98047

    merge

diff --cc f.txt
index 1111111,2222222..3333333
--- a/f.txt
+++ b/f.txt
@@@ -1,1 -1,1 +1,1 @@@
- a
 -b
++c
|};
  [%expect
    {|
    preamble |commit a757577ac7f79aa5fd48614f00553a6319b37a4a
    preamble |Author:     Ches Test <ches-test@example.invalid>
    preamble |AuthorDate: 2026-01-01T00:00:00+00:00
    preamble |Commit:     Ches Test <ches-test@example.invalid>
    preamble |CommitDate: 2026-01-01T00:00:00+00:00
    preamble |
    preamble |    Second
    preamble |
    preamble |    diff --git a/in/the b/message
    file "a.txt" -> "a.txt" Modified modes 100644..100644
      @@ -1,2 +1,2 @@  [-1,2 +1,2] section=""
        ctx   1   1 " "  "one"
        del   2   . "-"  "two"
        add   .   2 "+"  "TWO"
    preamble |commit fccb9f23e86da95d1fc3cbe2e744fff3ee40e500
    preamble |Merge: 90c5cb5 4e98047
    preamble |Author:     Ches Test <ches-test@example.invalid>
    preamble |
    preamble |    merge
    preamble |commit fccb9f23e86da95d1fc3cbe2e744fff3ee40e500
    preamble |Merge: 90c5cb5 4e98047
    preamble |
    preamble |    merge
    preamble |
    file "f.txt" -> "f.txt" Modified modes -..- combined no-line-actions
      @@@ -1,1 -1,1 +1,1 @@@  [-1,1 +1,1] section=""
        del   .   . "- " "a"
        del   .   . " -" "b"
        add   .   1 "++" "c"
    |}]
;;

let%expect_test "an empty line inside a hunk is empty context" =
  parse
    "diff --git a/f b/f\n\
     index 1..2 100644\n\
     --- a/f\n\
     +++ b/f\n\
     @@ -1,3 +1,3 @@\n\
    \ a\n\n\
     -b\n\
     +c\n";
  [%expect
    {|
    file "f" -> "f" Modified modes 100644..100644
      @@ -1,3 +1,3 @@  [-1,3 +1,3] section=""
        ctx   1   1 " "  "a"
        ctx   2   2 ""   ""
        del   3   . "-"  "b"
        add   .   3 "+"  "c"
    |}]
;;

(* Three hunks of 4 lines (8 bytes of text) each in one file, then a small file. *)
let three_hunks =
  String.concat
    [ "diff --git a/big b/big\nindex 1..2 100644\n--- a/big\n+++ b/big\n"
    ; "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
    ; "@@ -11,3 +11,3 @@\n k\n-l\n+L\n m\n"
    ; "@@ -21,3 +21,3 @@\n u\n-v\n+V\n w\n"
    ; "diff --git a/small b/small\nindex 1..2 100644\n--- a/small\n+++ b/small\n"
    ; "@@ -1 +1 @@\n-x\n+y\n"
    ]
;;

let%expect_test "per-file limits drop whole hunks and count them" =
  let limits file_lines file_bytes = { Diff.Limits.file_lines; file_bytes } in
  (* Two hunks fit in 8 lines; the third would exceed it. *)
  parse ~limits:(limits 8 1000) three_hunks;
  (* By bytes: 4 per hunk; 5 bytes keep only the first. *)
  parse ~limits:(limits 1000 5) three_hunks;
  (* Even the first hunk is too big: the file keeps only its header. *)
  parse ~limits:(limits 3 1000) three_hunks;
  [%expect
    {|
    file "big" -> "big" Modified modes 100644..100644
      truncated ((omitted_hunks 1) (omitted_lines 4) (cut false))
      @@ -1,3 +1,3 @@  [-1,3 +1,3] section=""
        ctx   1   1 " "  "a"
        del   2   . "-"  "b"
        add   .   2 "+"  "B"
        ctx   3   3 " "  "c"
      @@ -11,3 +11,3 @@  [-11,3 +11,3] section=""
        ctx  11  11 " "  "k"
        del  12   . "-"  "l"
        add   .  12 "+"  "L"
        ctx  13  13 " "  "m"
    file "small" -> "small" Modified modes 100644..100644
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "x"
        add   .   1 "+"  "y"
    file "big" -> "big" Modified modes 100644..100644
      truncated ((omitted_hunks 2) (omitted_lines 8) (cut false))
      @@ -1,3 +1,3 @@  [-1,3 +1,3] section=""
        ctx   1   1 " "  "a"
        del   2   . "-"  "b"
        add   .   2 "+"  "B"
        ctx   3   3 " "  "c"
    file "small" -> "small" Modified modes 100644..100644
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "x"
        add   .   1 "+"  "y"
    file "big" -> "big" Modified modes 100644..100644
      truncated ((omitted_hunks 3) (omitted_lines 12) (cut false))
    file "small" -> "small" Modified modes 100644..100644
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "x"
        add   .   1 "+"  "y"
    |}]
;;

let%expect_test "output cut at its limit" =
  let at pattern =
    String.prefix
      three_hunks
      (Option.value_exn (String.substr_index three_hunks ~pattern))
  in
  (* Inside the second hunk: it is dropped as incomplete. *)
  parse ~cut:true (at "+L");
  (* Exactly after the first hunk: it is complete and kept. *)
  parse ~cut:true (at "@@ -11");
  (* Inside the second file's header. *)
  parse ~cut:true (at "+++ b/small");
  (* Inside a show's preamble. *)
  parse ~cut:true "commit abc\nAuthor: som";
  (* Without [~cut], an incomplete hunk is an error. *)
  parse (at "+L");
  [%expect
    {|
    file "big" -> "big" Modified modes 100644..100644
      truncated ((omitted_hunks 1) (omitted_lines 2) (cut true))
      @@ -1,3 +1,3 @@  [-1,3 +1,3] section=""
        ctx   1   1 " "  "a"
        del   2   . "-"  "b"
        add   .   2 "+"  "B"
        ctx   3   3 " "  "c"
    (output cut)
    file "big" -> "big" Modified modes 100644..100644
      truncated ((omitted_hunks 0) (omitted_lines 0) (cut true))
      @@ -1,3 +1,3 @@  [-1,3 +1,3] section=""
        ctx   1   1 " "  "a"
        del   2   . "-"  "b"
        add   .   2 "+"  "B"
        ctx   3   3 " "  "c"
    (output cut)
    file "big" -> "big" Modified modes 100644..100644
      @@ -1,3 +1,3 @@  [-1,3 +1,3] section=""
        ctx   1   1 " "  "a"
        del   2   . "-"  "b"
        add   .   2 "+"  "B"
        ctx   3   3 " "  "c"
      @@ -11,3 +11,3 @@  [-11,3 +11,3] section=""
        ctx  11  11 " "  "k"
        del  12   . "-"  "l"
        add   .  12 "+"  "L"
        ctx  13  13 " "  "m"
      @@ -21,3 +21,3 @@  [-21,3 +21,3] section=""
        ctx  21  21 " "  "u"
        del  22   . "-"  "v"
        add   .  22 "+"  "V"
        ctx  23  23 " "  "w"
    file "small" -> "small" Modified modes 100644..100644
      truncated ((omitted_hunks 0) (omitted_lines 0) (cut true))
    (output cut)
    preamble |commit abc
    (output cut)
    (Error
     ("cannot parse diff output" "the last hunk is incomplete" (line_number 12)
      (line "")))
    |}]
;;

let%expect_test "malformed output is an error" =
  let file = "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n" in
  parse (file ^ "@@ -1 +1 @@\n-a\n+b\n+c\n");
  parse (file ^ "@@ -1,2 +1,2 @@\n-a\n+b\n@@ -5 +5 @@\n-x\n+y\n");
  parse (file ^ "@@ -1 +1\n-a\n+b\n");
  parse (file ^ "@@ -x +1 @@\n");
  parse (file ^ "@@@ -1 -1 +1 @@@\n");
  parse "diff --git a/f b/f\nsurprise header\n";
  parse "diff --git a/f b/f\nold mode 1006x4\n";
  parse "diff --git \"a/unterminated b/f\n--- \"a/bad\\q\"\n";
  parse "diff --git a/f b/f\n--- \"a/bad\\q\"\n";
  [%expect
    {|
    (Error
     ("cannot parse diff output" "unexpected line in a diff" (line_number 8)
      (line +c)))
    (Error
     ("cannot parse diff output" "hunk ended early" (line_number 8)
      (line "@@ -5 +5 @@")))
    (Error
     ("cannot parse diff output" "malformed hunk header" (line_number 5)
      (line "@@ -1 +1")))
    (Error
     ("cannot parse diff output" "malformed hunk header" (line_number 5)
      (line "@@ -x +1 @@")))
    (Error
     ("cannot parse diff output" "hunk header does not match the diff"
      (line_number 5) (line "@@@ -1 -1 +1 @@@")))
    (Error
     ("cannot parse diff output" "unexpected diff header line" (line_number 2)
      (line "surprise header")))
    (Error
     ("cannot parse diff output" "unexpected diff header line" (line_number 2)
      (line "old mode 1006x4")))
    (Error
     ("cannot parse diff output" "bad quoted path" (line_number 2)
      (line "--- \"a/bad\\q\"")))
    (Error
     ("cannot parse diff output" "bad quoted path" (line_number 2)
      (line "--- \"a/bad\\q\"")))
    |}]
;;
