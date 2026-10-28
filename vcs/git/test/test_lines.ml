(* Phase 4 end to end: line selections applied by git in fixture repositories. First an
   exhaustive check of Patch.hunks against an independent model, every subset of a file's
   changed lines, forward and reversed; then Backend.plan for Lines targets, printing the
   decisions, running them and showing the index and work tree. *)

open! Core
open Ches_vcs
module Fixture = Ches_vcs_fixture.Fixture_repo
module Git = Ches_vcs_git
module B = Ches_vcs_git.Backend
module Patch = Ches_vcs_git.Patch
open Test_plan

(* {2 Patch.hunks against a model} *)

(* A file's lines without terminators, and whether its last line ends in a newline. *)
let split text =
  if String.is_empty text
  then [||], true
  else (
    let parts = String.split text ~on:'\n' in
    match List.last_exn parts with
    | "" -> Array.of_list (List.drop_last_exn parts), true
    | _ -> Array.of_list parts, false)
;;

(* What applying the selected changes gives, computed from the two texts and the diff's
   line numbers alone: forward from the old text, keeping unselected removals and adding
   selected additions; reversed from the new text, keeping unselected additions and
   restoring selected removals. Each line remembers where it came from: the result ends
   without a newline only if its last line is the last line of a side that had none.
   [None] when the file should not exist (an added file all unstaged, a deleted one all
   staged). *)
let model (file : Diff.File.t) ~old_text ~new_text ~selected ~reverse =
  let old_lines, old_newline = split old_text in
  let new_lines, new_newline = split new_text in
  let base = if reverse then new_lines else old_lines in
  let result = Queue.create () in
  let pos = ref 0 in
  let copy_to stop =
    while !pos < stop do
      let i = !pos in
      let origin = if reverse then None, Some i else Some i, None in
      Queue.enqueue result (base.(i), fst origin, snd origin);
      incr pos
    done
  in
  List.iteri file.hunks ~f:(fun h (hunk : Diff.Hunk.t) ->
    let start, count =
      if reverse then hunk.new_start, hunk.new_count else hunk.old_start, hunk.old_count
    in
    copy_to (if count = 0 then start else start - 1);
    List.iteri hunk.lines ~f:(fun l (line : Diff.Line.t) ->
      let old_index = Option.map line.old_line ~f:pred in
      let new_index = Option.map line.new_line ~f:pred in
      let push () = Queue.enqueue result (line.text, old_index, new_index) in
      match line.kind, selected h l, reverse with
      | Context, _, _ -> push ()
      | No_newline, _, _ -> ()
      | Removed, false, false | Added, true, false -> push ()
      | Added, false, true | Removed, true, true -> push ()
      | Removed, true, false | Added, false, false -> ()
      | Added, true, true | Removed, false, true -> ());
    pos := !pos + count);
  copy_to (Array.length base);
  let lines = Queue.to_list result in
  let is_last index lines =
    Option.equal Int.equal index (Some (Array.length lines - 1))
  in
  match lines, file.change, reverse with
  | [], Deleted, false | [], Added, true -> None
  | [], _, _ -> Some ""
  | _ :: _, _, _ ->
    let _, old_index, new_index = List.last_exn lines in
    let no_newline =
      (is_last old_index old_lines && not old_newline)
      || (is_last new_index new_lines && not new_newline)
    in
    Some
      (String.concat ~sep:"\n" (List.map lines ~f:(fun (text, _, _) -> text))
       ^ if no_newline then "" else "\n")
;;

let apply t flags patch =
  Fixture.run
    t
    (Git.Cli.mutate
       ~stdin:(Data patch)
       ~cwd:t.work
       (("apply" :: flags) @ [ "--whitespace=nowarn" ]))
;;

let index_text t path =
  match Fixture.git t [ "ls-files"; "--cached"; "--"; path ] with
  | "" -> None
  | _ -> Some (Fixture.git t [ "show"; ":" ^ path ])
;;

let work_text t path =
  match Core_unix.access (Fixture.path t path) [ `Exists ] with
  | Error _ -> None
  | Ok () -> Some (In_channel.read_all (Fixture.path t path))
;;

(* Every non-empty subset of [file]'s changes, as selections. *)
let subsets (file : Diff.File.t) =
  let changes =
    List.concat_mapi file.hunks ~f:(fun h (hunk : Diff.Hunk.t) ->
      List.filter_mapi hunk.lines ~f:(fun l (line : Diff.Line.t) ->
        match line.kind with
        | Added | Removed -> Some (h, l)
        | Context | No_newline -> None))
  in
  let n = List.length changes in
  List.init
    ((1 lsl n) - 1)
    ~f:(fun mask ->
      let chosen = List.filteri changes ~f:(fun i _ -> (mask + 1) land (1 lsl i) <> 0) in
      let selections =
        List.group chosen ~break:(fun (a, _) (b, _) -> a <> b)
        |> List.map ~f:(fun group ->
          fst (List.hd_exn group), Patch.Selection.Lines (List.map group ~f:snd))
      in
      let selected h l = List.mem chosen (h, l) ~equal:[%equal: int * int] in
      selections, selected)
;;

type mode =
  | Stage (** Forward, [--cached], from the index at HEAD. *)
  | Unstage (** Reversed, [--cached], from everything staged. *)
  | Discard (** Reversed in the work tree, from the index at HEAD. *)
[@@deriving sexp_of]

(* [old_text] committed (absent: [None]), [new_text] in the work tree (absent: [None]);
   for each mode, every subset applied by git from a fresh base and compared with the
   model. Prints the number of subsets per mode and every mismatch. *)
let exhaustive ?(intent_to_add = false) ~path ~old_text ~new_text modes =
  Fixture.with_repo (fun t ->
    Fixture.write t "keep" "keep\n";
    Option.iter old_text ~f:(Fixture.write t path);
    commit t "base";
    let write_new () =
      match new_text with
      | Some text -> Fixture.write t path text
      | None ->
        (match Core_unix.access (Fixture.path t path) [ `Exists ] with
         | Ok () -> Core_unix.unlink (Fixture.path t path)
         | Error _ -> ())
    in
    write_new ();
    let base_index () =
      git t [ "read-tree"; "HEAD" ];
      if intent_to_add then git t [ "add"; "-N"; "--"; path ]
    in
    List.iter modes ~f:(fun mode ->
      base_index ();
      let reverse, flags, target, read =
        match mode with
        | Stage -> false, [ "--cached" ], B.Unstaged [ path ], index_text
        | Unstage ->
          git t [ "add"; "-A" ];
          true, [ "--cached"; "--reverse" ], B.Staged [ path ], index_text
        | Discard -> true, [ "--reverse" ], B.Unstaged [ path ], work_text
      in
      let file = List.hd_exn (diff t (snapshot t) target).files in
      let reset () =
        match mode with
        | Stage -> base_index ()
        | Unstage -> git t [ "add"; "-A" ]
        | Discard -> write_new ()
      in
      let subsets = subsets file in
      let mismatches =
        List.count subsets ~f:(fun (selections, selected) ->
          let expected =
            model
              file
              ~old_text:(Option.value old_text ~default:"")
              ~new_text:(Option.value new_text ~default:"")
              ~selected
              ~reverse
          in
          let patch = ok_exn (Patch.hunks file selections ~reverse) in
          let result = apply t flags patch in
          let actual =
            if Exec.Result.succeeded result
            then read t path
            else Some ("apply failed: " ^ result.stderr)
          in
          reset ();
          if [%equal: string option] expected actual
          then false
          else (
            print_s
              [%message
                "mismatch"
                  (mode : mode)
                  (selections : (int * Patch.Selection.t) list)
                  (expected : string option)
                  (actual : string option)
                  patch];
            true))
      in
      printf
        "%s: %d subsets, %d mismatches\n"
        (match mode with
         | Stage -> "stage"
         | Unstage -> "unstage"
         | Discard -> "discard")
        (List.length subsets)
        mismatches))
;;

let%expect_test "every subset of changed lines, as git applies it" =
  let lines n f = String.concat (List.init n ~f:(fun i -> f (i + 1))) in
  print_endline "-- two hunks";
  exhaustive
    ~path:"a.txt"
    ~old_text:(Some (lines 14 (sprintf "line %d\n")))
    ~new_text:
      (Some
         (lines 14 (fun i ->
            match i with
            | 2 -> "LINE 2\n"
            | 12 -> "new 12a\nnew 12b\n"
            | i -> sprintf "line %d\n" i)))
    [ Stage; Unstage; Discard ];
  print_endline "-- no newline at the end of either side";
  exhaustive
    ~path:"a.txt"
    ~old_text:(Some "a\nb\nx")
    ~new_text:(Some "a\nB\ny")
    [ Stage; Unstage; Discard ];
  print_endline "-- the old side lacks the newline; lines appended";
  exhaustive
    ~path:"a.txt"
    ~old_text:(Some "a\nx")
    ~new_text:(Some "a\nx\ny\nz\n")
    [ Stage; Unstage; Discard ];
  print_endline "-- the new side loses its newline";
  exhaustive
    ~path:"a.txt"
    ~old_text:(Some "s\nend\n")
    ~new_text:(Some "s\nEND\nmore")
    [ Stage; Unstage; Discard ];
  print_endline "-- CRLF";
  exhaustive
    ~path:"a.txt"
    ~old_text:(Some "a\r\nb\r\nc\r\n")
    ~new_text:(Some "a\r\nB\r\nc\r\nd\r\n")
    [ Stage; Unstage; Discard ];
  print_endline "-- a deleted file (no newline at its end)";
  exhaustive
    ~path:"a.txt"
    ~old_text:(Some "1\n2\n3")
    ~new_text:None
    [ Stage; Unstage; Discard ];
  print_endline "-- a new file: intent-to-add staged, then staged and unstaged";
  exhaustive
    ~intent_to_add:true
    ~path:"a.txt"
    ~old_text:None
    ~new_text:(Some "1\n2\n3\n")
    [ Stage ];
  exhaustive ~path:"a.txt" ~old_text:None ~new_text:(Some "1\n2\n3") [ Unstage ];
  [%expect
    {|
    -- two hunks
    stage: 31 subsets, 0 mismatches
    unstage: 31 subsets, 0 mismatches
    discard: 31 subsets, 0 mismatches
    -- no newline at the end of either side
    stage: 15 subsets, 0 mismatches
    unstage: 15 subsets, 0 mismatches
    discard: 15 subsets, 0 mismatches
    -- the old side lacks the newline; lines appended
    stage: 15 subsets, 0 mismatches
    unstage: 15 subsets, 0 mismatches
    discard: 15 subsets, 0 mismatches
    -- the new side loses its newline
    stage: 7 subsets, 0 mismatches
    unstage: 7 subsets, 0 mismatches
    discard: 7 subsets, 0 mismatches
    -- CRLF
    stage: 7 subsets, 0 mismatches
    unstage: 7 subsets, 0 mismatches
    discard: 7 subsets, 0 mismatches
    -- a deleted file (no newline at its end)
    stage: 7 subsets, 0 mismatches
    unstage: 7 subsets, 0 mismatches
    discard: 7 subsets, 0 mismatches
    -- a new file: intent-to-add staged, then staged and unstaged
    stage: 7 subsets, 0 mismatches
    unstage: 7 subsets, 0 mismatches
    |}]
;;

(* {2 Backend.plan for line targets} *)

(* The [Lines] target for [hunks] (hunk index, line indices) of [path] in the diff of
   [target], as the view would build it from a Visual selection. *)
let lines t snapshot target ~path hunks =
  let file =
    List.find_exn (diff t snapshot target).files ~f:(fun file ->
      String.equal (Diff.File.path file) path)
  in
  B.Target.Lines
    { section = Option.value_exn (B.diff_section target)
    ; file
    ; hunks = List.map hunks ~f:(fun (hunk, lines) -> hunk, Patch.Selection.Lines lines)
    }
;;

(* The index and the work tree against it, hunks only. *)
let diffs t =
  let show label args =
    Fixture.git t ([ "diff"; "--no-color"; "--no-ext-diff" ] @ args)
    |> String.split_lines
    |> List.filter ~f:(fun line ->
      not
        (List.exists [ "diff --git"; "index "; "--- "; "+++ " ] ~f:(fun prefix ->
           String.is_prefix line ~prefix)))
    |> List.iter ~f:(fun line -> printf "  %s |%s\n" label line)
  in
  show "staged" [ "--cached" ];
  show "unstaged" []
;;

let index t path = printf "  index %s: %S\n" path (Fixture.git t [ "show"; ":" ^ path ])

let%expect_test "stage 2 of 3 added lines; a removed line alone; unstage one line" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\nb\n";
    Fixture.write t "r.txt" "one\ntwo\nthree\n";
    commit t "base";
    (* a.txt: " a" (0), "+x" (1), "+y" (2), "+z" (3), " b" (4). *)
    Fixture.write t "a.txt" "a\nx\ny\nz\nb\n";
    (* r.txt: " one" (0), "-two" (1), "+TWO" (2), " three" (3). *)
    Fixture.write t "r.txt" "one\nTWO\nthree\n";
    let s = snapshot t in
    act
      ~snapshot:s
      t
      (Stage (lines t s (Unstaged [ "a.txt" ]) ~path:"a.txt" [ 0, [ 1; 3 ] ]));
    index t "a.txt";
    act
      ~snapshot:s
      t
      (Stage (lines t s (Unstaged [ "r.txt" ]) ~path:"r.txt" [ 0, [ 1 ] ]));
    index t "r.txt";
    diffs t;
    (* a.txt's staged hunk: " a" (0), "+x" (1), "+z" (2), " b" (3). *)
    let s = snapshot t in
    act
      ~snapshot:s
      t
      (Unstage (lines t s (Staged [ "a.txt" ]) ~path:"a.txt" [ 0, [ 2 ] ]));
    index t "a.txt";
    diffs t);
  [%expect
    {|
    run
      plan "Stage 2 lines of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |MM a.txt
      status | M r.txt
      index a.txt: "a\nx\nz\nb\n"
    run
      plan "Stage 1 line of r.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |MM a.txt
      status |MM r.txt
      index r.txt: "one\nthree\n"
      staged |@@ -1,2 +1,4 @@
      staged | a
      staged |+x
      staged |+z
      staged | b
      staged |@@ -1,3 +1,2 @@
      staged | one
      staged |-two
      staged | three
      unstaged |@@ -1,4 +1,5 @@
      unstaged | a
      unstaged | x
      unstaged |+y
      unstaged | z
      unstaged | b
      unstaged |@@ -1,2 +1,3 @@
      unstaged | one
      unstaged |+TWO
      unstaged | three
    run
      plan "Unstage 1 line of a.txt"
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn < patch
      status |MM a.txt
      status |MM r.txt
      index a.txt: "a\nx\nb\n"
      staged |@@ -1,2 +1,3 @@
      staged | a
      staged |+x
      staged | b
      staged |@@ -1,3 +1,2 @@
      staged | one
      staged |-two
      staged | three
      unstaged |@@ -1,3 +1,5 @@
      unstaged | a
      unstaged | x
      unstaged |+y
      unstaged |+z
      unstaged | b
      unstaged |@@ -1,2 +1,3 @@
      unstaged | one
      unstaged |+TWO
      unstaged | three
    |}]
;;

let%expect_test "discard lines: unstaged (the work tree exactly) and staged" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\nb\n";
    Fixture.write t "r.txt" "one\ntwo\nthree\n";
    commit t "base";
    Fixture.write t "a.txt" "a\nx\ny\nz\nb\n";
    Fixture.write t "r.txt" "one\nTWO\nthree\n";
    git t [ "add"; "r.txt" ];
    let s = snapshot t in
    act
      ~snapshot:s
      t
      (Discard (lines t s (Unstaged [ "a.txt" ]) ~path:"a.txt" [ 0, [ 1; 2 ] ]));
    contents t "a.txt";
    let s = snapshot t in
    (* " a" (0), "+z" (1), " b" (2): one line. *)
    act
      ~snapshot:s
      t
      (Discard (lines t s (Unstaged [ "a.txt" ]) ~path:"a.txt" [ 0, [ 0; 1 ] ]));
    contents t "a.txt";
    (* Staged: drop the added TWO, keep the removal of two. *)
    let s = snapshot t in
    act
      ~snapshot:s
      t
      (Discard (lines t s (Staged [ "r.txt" ]) ~path:"r.txt" [ 0, [ 2 ] ]));
    contents t "r.txt";
    diffs t;
    (* Both removed and added staged lines, then refused once the work tree differs. *)
    Fixture.write t "r.txt" "ONE\nthree\nfour\n";
    git t [ "add"; "r.txt" ];
    let s = snapshot t in
    let both = lines t s (Staged [ "r.txt" ]) ~path:"r.txt" [ 0, [ 0; 1; 2; 3 ] ] in
    Fixture.write t "r.txt" "ONE\nthree\nfour\nfive\n";
    act t (Discard both);
    git t [ "checkout"; "--"; "r.txt" ];
    act t (Discard both);
    contents t "r.txt");
  [%expect
    {|
    confirm "Discard lines": Discard 2 lines of a.txt? Their unstaged changes are lost.
      plan "Discard 2 lines of a.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --reverse --whitespace=nowarn < patch
      status | M a.txt
      status |M  r.txt
      a.txt: "a\nz\nb\n"
    confirm "Discard lines": Discard 1 line of a.txt? Its unstaged change is lost.
      plan "Discard 1 line of a.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --reverse --whitespace=nowarn < patch
      status |M  r.txt
      a.txt: "a\nb\n"
    confirm "Discard lines": Discard 1 staged line of r.txt? Its change is removed from the index and the work tree and lost.
      plan "Discard 1 staged line of r.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn < patch
      status |M  r.txt
      r.txt: "one\nthree\n"
      staged |@@ -1,3 +1,2 @@
      staged | one
      staged |-two
      staged | three
    refused: r.txt also has unstaged changes: discard or stage them first; nothing ran
    confirm "Discard lines": Discard 3 staged lines of r.txt? Their changes are removed from the index and the work tree and lost.
      plan "Discard 3 staged lines of r.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn < patch
      status |M  r.txt
      r.txt: "one\ntwo\nthree\nfour\n"
    |}]
;;

let%expect_test "a selection across two hunks is one patch, applied atomically" =
  Fixture.with_repo (fun t ->
    let base = List.init 14 ~f:(fun i -> sprintf "line %d\n" (i + 1)) in
    Fixture.write t "a.txt" (String.concat base);
    commit t "base";
    Fixture.write
      t
      "a.txt"
      (String.concat
         (List.mapi base ~f:(fun i line ->
            match i with
            | 1 -> "LINE 2\n"
            | 11 -> "new 12a\nnew 12b\n"
            | _ -> line)));
    let s = snapshot t in
    let file = List.hd_exn (diff t s (Unstaged [ "a.txt" ])).files in
    List.iteri file.hunks ~f:(fun i (hunk : Diff.Hunk.t) ->
      printf
        "hunk %d: %s\n"
        i
        (String.concat
           ~sep:" "
           (List.mapi hunk.lines ~f:(fun l (line : Diff.Line.t) ->
              sprintf "%d%s%s" l line.prefix line.text))));
    (* Hunk 1 whole (by its lines), and only "+new 12a" of hunk 2: its "-line 12" stays,
       as context. *)
    let selection =
      lines t s (Unstaged [ "a.txt" ]) ~path:"a.txt" [ 0, [ 1; 2 ]; 1, [ 4 ] ]
    in
    act ~snapshot:s t (Stage selection);
    diffs t;
    (* The same selection again is stale: its check fails and nothing changes. *)
    act ~snapshot:s t (Stage selection);
    diffs t;
    (* A discard across both hunks whose second hunk no longer matches the work tree: the
       first hunk is not discarded either. *)
    git t [ "reset"; "-q" ];
    let s = snapshot t in
    let target =
      lines t s (Unstaged [ "a.txt" ]) ~path:"a.txt" [ 0, [ 1; 2 ]; 1, [ 4 ] ]
    in
    Fixture.write
      t
      "a.txt"
      (String.concat
         (List.mapi base ~f:(fun i line ->
            match i with
            | 1 -> "LINE 2\n"
            | 11 -> "new 12a\nchanged\n"
            | _ -> line)));
    act ~snapshot:s t (Discard target);
    contents t "a.txt");
  [%expect
    {|
    hunk 0: 0 line 1 1-line 2 2+LINE 2 3 line 3 4 line 4 5 line 5
    hunk 1: 0 line 9 1 line 10 2 line 11 3-line 12 4+new 12a 5+new 12b 6 line 13 7 line 14
    run
      plan "Stage 3 lines of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |MM a.txt
      staged |@@ -1,5 +1,5 @@
      staged | line 1
      staged |-line 2
      staged |+LINE 2
      staged | line 3
      staged | line 4
      staged | line 5
      staged |@@ -10,5 +10,6 @@ line 9
      staged | line 10
      staged | line 11
      staged | line 12
      staged |+new 12a
      staged | line 13
      staged | line 14
      unstaged |@@ -9,7 +9,7 @@ line 8
      unstaged | line 9
      unstaged | line 10
      unstaged | line 11
      unstaged |-line 12
      unstaged | new 12a
      unstaged |+new 12b
      unstaged | line 13
      unstaged | line 14
    run
      plan "Stage 3 lines of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      failed: exit 1: error: patch failed: a.txt:1 / error: a.txt: patch does not apply
      (skipped)
      status |MM a.txt
      staged |@@ -1,5 +1,5 @@
      staged | line 1
      staged |-line 2
      staged |+LINE 2
      staged | line 3
      staged | line 4
      staged | line 5
      staged |@@ -10,5 +10,6 @@ line 9
      staged | line 10
      staged | line 11
      staged | line 12
      staged |+new 12a
      staged | line 13
      staged | line 14
      unstaged |@@ -9,7 +9,7 @@ line 8
      unstaged | line 9
      unstaged | line 10
      unstaged | line 11
      unstaged |-line 12
      unstaged | new 12a
      unstaged |+new 12b
      unstaged | line 13
      unstaged | line 14
    confirm "Discard lines": Discard 3 lines of a.txt? Their unstaged changes are lost.
      plan "Discard 3 lines of a.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --reverse --whitespace=nowarn < patch
      failed: exit 1: error: patch failed: a.txt:9 / error: a.txt: patch does not apply
      (skipped)
      status | M a.txt
      a.txt: "line 1\nLINE 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\nline 11\nnew 12a\nchanged\nline 13\nline 14\n"
    |}]
;;

let%expect_test "no newline at the end: the staged file is exactly right" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\nx";
    commit t "base";
    (* " a" (0), "-x" (1), marker (2), "+x" (3), "+y" (4), marker (5). *)
    Fixture.write t "a.txt" "a\nx\ny";
    let s = snapshot t in
    act
      ~snapshot:s
      t
      (Stage (lines t s (Unstaged [ "a.txt" ]) ~path:"a.txt" [ 0, [ 4 ] ]));
    index t "a.txt";
    diffs t;
    let s = snapshot t in
    act
      ~snapshot:s
      t
      (Unstage (lines t s (Staged [ "a.txt" ]) ~path:"a.txt" [ 0, [ 1; 2; 3; 4; 5 ] ]));
    index t "a.txt");
  [%expect
    {|
    run
      plan "Stage 1 line of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |M  a.txt
      index a.txt: "a\nx\ny"
      staged |@@ -1,2 +1,3 @@
      staged | a
      staged |-x
      staged |\ No newline at end of file
      staged |+x
      staged |+y
      staged |\ No newline at end of file
    run
      plan "Unstage 3 lines of a.txt"
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn < patch
      status | M a.txt
      index a.txt: "a\nx"
    |}]
;;

let%expect_test "line refusals and texts" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "one\ntwo\nthree\n";
    Fixture.write t "s.txt" "s\n";
    Fixture.write t "bin.dat" "\000\001";
    commit t "base";
    Fixture.write t "a.txt" "one\nTWO\nthree\n";
    Fixture.write t "s.txt" "S\n";
    git t [ "add"; "s.txt" ];
    Fixture.write t "bin.dat" "\000\002";
    Fixture.write t "new.txt" "n1\nn2\n";
    Fixture.write t "ita.txt" "i1\ni2\n";
    git t [ "add"; "-N"; "ita.txt" ];
    let s = snapshot t in
    let a = lines t s (Unstaged [ "a.txt" ]) ~path:"a.txt" in
    let staged = lines t s (Staged [ "s.txt" ]) ~path:"s.txt" in
    let untracked = lines t s (Untracked "new.txt") ~path:"new.txt" [ 0, [ 0 ] ] in
    let decide action = ignore (decide s action : Ches_vcs.Backend.Plan.t option) in
    print_endline "-- untracked";
    decide (Stage untracked);
    decide (Unstage untracked);
    decide (Discard untracked);
    print_endline "-- no change selected";
    decide (Stage (a [ 0, [ 0; 3 ] ]));
    decide (Stage (a []));
    print_endline "-- index errors, a binary file";
    decide (Stage (a [ 0, [ 7 ] ]));
    decide (Stage (a [ 1, [ 0 ] ]));
    decide (Stage (lines t s (Unstaged [ "bin.dat" ]) ~path:"bin.dat" []));
    print_endline "-- verb and section";
    decide (Stage (staged [ 0, [ 0 ] ]));
    decide (Unstage (a [ 0, [ 1 ] ]));
    print_endline "-- singular and plural texts";
    decide (Stage (a [ 0, [ 1 ] ]));
    decide (Unstage (staged [ 0, [ 0; 1 ] ]));
    decide (Discard (a [ 0, [ 1 ] ]));
    decide (Discard (a [ 0, [ 1; 2 ] ]));
    decide (Discard (staged [ 0, [ 0 ] ]));
    decide (Discard (staged [ 0, [ 0; 1 ] ]));
    print_endline "-- a Hunk target with a Lines selection plans as Lines";
    let file = List.hd_exn (diff t s (Unstaged [ "a.txt" ])).files in
    decide (Stage (Hunk { section = Unstaged; file; hunk = 0; selection = Lines [ 2 ] }));
    print_endline "-- intent-to-add: staged by lines, not discarded";
    decide (Stage (lines t s (Unstaged [ "ita.txt" ]) ~path:"ita.txt" [ 0, [ 1 ] ]));
    decide (Discard (lines t s (Unstaged [ "ita.txt" ]) ~path:"ita.txt" [ 0, [ 1 ] ]));
    print_endline "-- no longer listed (staged meanwhile)";
    let stale = a [ 0, [ 1 ] ] in
    git t [ "add"; "a.txt" ];
    ignore (Test_plan.decide (snapshot t) (Stage stale) : Ches_vcs.Backend.Plan.t option));
  [%expect
    {|
    -- untracked
    refused: Stage the whole untracked file first (s on its row); nothing ran
    refused: new.txt is not staged; nothing ran
    refused: Stage the whole untracked file first (s on its row); nothing ran
    -- no change selected
    refused: No changes selected; nothing ran
    refused: No changes selected; nothing ran
    -- index errors, a binary file
    refused: Line 8 of hunk 1/1 of a.txt does not exist (it has 4)
    refused: Hunk 2 of a.txt does not exist (it has 1)
    refused: Line actions do not apply to bin.dat: it is binary
    -- verb and section
    refused: s.txt is already staged; nothing ran
    refused: a.txt is not staged; nothing ran
    -- singular and plural texts
    run
      plan "Stage 1 line of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
    run
      plan "Unstage 2 lines of s.txt"
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn < patch
    confirm "Discard lines": Discard 1 line of a.txt? Its unstaged change is lost.
      plan "Discard 1 line of a.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --reverse --whitespace=nowarn < patch
    confirm "Discard lines": Discard 2 lines of a.txt? Their unstaged changes are lost.
      plan "Discard 2 lines of a.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --reverse --whitespace=nowarn < patch
    confirm "Discard lines": Discard 1 staged line of s.txt? Its change is removed from the index and the work tree and lost.
      plan "Discard 1 staged line of s.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn < patch
    confirm "Discard lines": Discard 2 staged lines of s.txt? Their changes are removed from the index and the work tree and lost.
      plan "Discard 2 staged lines of s.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn < patch
    -- a Hunk target with a Lines selection plans as Lines
    run
      plan "Stage 1 line of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
    -- intent-to-add: staged by lines, not discarded
    run
      plan "Stage 1 line of ita.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
    refused: ita.txt is intent-to-add (git add -N): discarding would empty it; nothing ran
    -- no longer listed (staged meanwhile)
    refused: a.txt is no longer listed; refresh (g r); nothing ran
    |}]
;;

let%expect_test "conflicted files have no line actions" =
  Fixture.with_repo (fun t ->
    Fixture.write t "c.txt" "base\n";
    commit t "base";
    git t [ "checkout"; "-q"; "-b"; "other" ];
    Fixture.write t "c.txt" "theirs\n";
    commit t "theirs";
    git t [ "checkout"; "-q"; "main" ];
    Fixture.write t "c.txt" "ours\n";
    commit t "ours";
    (* The merge stops on the conflict (exit 1). *)
    ignore
      (Fixture.run t (Git.Cli.mutate ~cwd:t.work [ "merge"; "-q"; "other" ])
       : Exec.Result.t);
    let s = snapshot t in
    let file = List.hd_exn (diff t s (Conflicted [ "c.txt" ])).files in
    let target =
      B.Target.Lines { section = Conflicted; file; hunks = [ 0, Lines [ 0 ] ] }
    in
    List.iter [ B.Stage target; Unstage target; Discard target ] ~f:(fun action ->
      ignore (decide s action : Ches_vcs.Backend.Plan.t option)));
  [%expect
    {|
    refused: c.txt is conflicted: conflict resolution is not supported yet; resolve it in the editor, then stage it (s) to mark it resolved; nothing ran
    refused: c.txt is conflicted: conflict resolution is not supported yet; resolve it in the editor, then stage it (s) to mark it resolved; nothing ran
    refused: c.txt is conflicted: conflict resolution is not supported yet; resolve it in the editor, then stage it (s) to mark it resolved; nothing ran
    |}]
;;
