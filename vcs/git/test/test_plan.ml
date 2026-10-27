(* Backend.plan end to end: decisions for actions chosen in real fixture snapshots (hunks
   from real parsed diffs), then their steps run the way the runner runs a mutation
   (stopping at the first failed step), then [git status] afterwards. Commands print
   without Cli.prefix; paths under the fixture's temp directory print as $DIR. *)

open! Core
open Ches_vcs
module Fixture = Ches_vcs_fixture.Fixture_repo
module Git = Ches_vcs_git
module B = Ches_vcs_git.Backend

let relative (t : Fixture.t) text =
  String.substr_replace_all text ~pattern:t.dir ~with_:"$DIR"
;;

let git t args = ignore (Fixture.git t args : string)
let commit t message = ignore (Fixture.commit_all t message : string)

let repository (t : Fixture.t) =
  match B.detected ~cwd:t.work (Fixture.run_steps t (B.detect ~cwd:t.work)) with
  | Found repository -> repository
  | _ -> failwith "not a repository"
;;

let snapshot ?(ignored = false) t =
  let refresh = { Ches_vcs.Backend.Refresh.default with ignored } in
  let repository = repository t in
  ok_exn
    (B.snapshot repository refresh (Fixture.run_steps t (B.refresh repository refresh)))
;;

let diff t (snapshot : B.snapshot) target =
  ok_exn
    (B.parse_diff
       target
       Diff.Limits.default
       (Fixture.run_steps t (B.diff snapshot.repository target)))
;;

let file section path = B.Target.File { section; path }

(* Hunk [index] of [path] in the diff of [target], as the view would choose it. *)
let hunk t snapshot target ~path index =
  let file =
    List.find_exn (diff t snapshot target).files ~f:(fun file ->
      String.equal (Diff.File.path file) path)
  in
  B.Target.Hunk
    { section = Option.value_exn (B.diff_section target)
    ; file
    ; hunk = index
    ; selection = Whole
    }
;;

let command spec =
  String.chop_prefix_if_exists
    (Exec.Spec.to_string_hum spec)
    ~prefix:(Exec.Spec.to_string_hum (Git.Cli.mutate ~cwd:"/" []) ^ " ")
;;

let print_plan (plan : Ches_vcs.Backend.Plan.t) =
  printf
    "  plan %S%s\n"
    plan.title
    (if plan.rewrites_worktree then " (rewrites the work tree)" else "");
  List.iter plan.steps ~f:(function
    | Run spec ->
      printf
        "  $ %s%s\n"
        (command spec)
        (match spec.stdin with
         | Null -> ""
         | Data _ -> " < patch")
    | Read_file _ -> print_endline "  (file read)")
;;

let decide (snapshot : B.snapshot) action =
  match B.plan snapshot.repository snapshot action with
  | Refused message ->
    printf "refused: %s\n" message;
    None
  | Run plan ->
    print_endline "run";
    print_plan plan;
    Some plan
  | Confirm { title; message; plan } ->
    printf "confirm %S: %s\n" title message;
    print_plan plan;
    Some plan
;;

(* As the runner runs one mutation job: steps in order, stopping at the first that fails. *)
let execute t (plan : Ches_vcs.Backend.Plan.t) =
  let rec go = function
    | [] -> ()
    | step :: rest ->
      (match Fixture.run_steps t [ step ] with
       | [ { outcome = Ran result; _ } ] when Exec.Result.succeeded result -> go rest
       | [ { outcome = Ran result; _ } ] ->
         printf
           "  failed: %s: %s\n"
           (Exec.Result.status_hum result)
           (relative t (String.strip result.stderr)
            |> String.substr_replace_all ~pattern:"\n" ~with_:" / ");
         List.iter rest ~f:(fun _ -> print_endline "  (skipped)")
       | _ -> failwith "unexpected report")
  in
  go plan.steps
;;

let status t =
  Fixture.git t [ "status"; "--porcelain"; "--untracked-files=all" ]
  |> String.split_lines
  |> List.iter ~f:(fun line -> printf "  status |%s\n" line)
;;

let contents t path =
  match Core_unix.access (Fixture.path t path) [ `Exists ] with
  | Error _ -> printf "  %s: (absent)\n" path
  | Ok () -> printf "  %s: %S\n" path (In_channel.read_all (Fixture.path t path))
;;

let cached t =
  Fixture.git t [ "diff"; "--cached"; "--no-color"; "--no-ext-diff"; "-U0" ]
  |> String.split_lines
  |> List.filter ~f:(fun line ->
    List.exists [ "@@"; "+"; "-"; "rename"; "new"; "deleted" ] ~f:(fun prefix ->
      String.is_prefix line ~prefix))
  |> List.iter ~f:(fun line -> printf "  cached |%s\n" line)
;;

(* Decide against a fresh snapshot (or [snapshot]), run what was decided, show the status. *)
let act ?snapshot:s t action =
  let s =
    match s with
    | Some s -> s
    | None -> snapshot t
  in
  Option.iter (decide s action) ~f:(fun plan ->
    execute t plan;
    status t)
;;

let%expect_test "file actions: stage, unstage, discard; the full command line" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "one\n";
    commit t "base";
    Fixture.write t "a.txt" "one\ntwo\n";
    let s = snapshot t in
    (match B.plan s.repository s (Stage (file Unstaged "a.txt")) with
     | Run { steps = [ Run spec ]; _ } ->
       print_endline (Exec.Spec.to_string_hum spec);
       print_s [%sexp (spec.kind : Exec.Kind.t), (relative t spec.cwd : string)]
     | _ -> assert false);
    act t (Stage (file Unstaged "a.txt"));
    act t (Unstage (file Staged "a.txt"));
    act t (Discard (file Unstaged "a.txt"));
    contents t "a.txt");
  [%expect
    {|
    git --no-pager -c color.ui=false -c core.quotepath=false --literal-pathspecs add --all -- a.txt
    (Mutate $DIR/work)
    run
      plan "Stage a.txt"
      $ --literal-pathspecs add --all -- a.txt
      status |M  a.txt
    run
      plan "Unstage a.txt"
      $ --literal-pathspecs restore --staged -- a.txt
      status | M a.txt
    confirm "Discard changes": Discard the unstaged changes to a.txt? They are lost; staged changes are kept.
      plan "Discard unstaged changes to a.txt" (rewrites the work tree)
      $ --literal-pathspecs restore --worktree -- a.txt
      a.txt: "one\n"
    |}]
;;

let%expect_test "discarding staged changes: modified, new, deleted; partially staged" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "one\n";
    Fixture.write t "d.txt" "gone\n";
    Fixture.write t "p.txt" "p\n";
    commit t "base";
    Fixture.write t "a.txt" "ONE\n";
    Fixture.write t "new.txt" "new\n";
    Fixture.write t "p.txt" "P\n";
    git t [ "add"; "a.txt"; "new.txt"; "p.txt" ];
    git t [ "rm"; "-q"; "d.txt" ];
    Fixture.write t "p.txt" "P2\n";
    status t;
    let s = snapshot t in
    act ~snapshot:s t (Discard (file Staged "p.txt"));
    act ~snapshot:s t (Discard (hunk t s (Staged [ "p.txt" ]) ~path:"p.txt" 0));
    act t (Discard (file Staged "a.txt"));
    contents t "a.txt";
    act t (Discard (file Staged "new.txt"));
    contents t "new.txt";
    act t (Discard (file Staged "d.txt"));
    contents t "d.txt");
  [%expect
    {|
      status |M  a.txt
      status |D  d.txt
      status |A  new.txt
      status |MM p.txt
    refused: p.txt also has unstaged changes: discard or stage them first; nothing ran
    refused: p.txt also has unstaged changes: discard or stage them first; nothing ran
    confirm "Discard changes": Discard the staged changes to a.txt? They are lost: it returns to HEAD in the index and the work tree.
      plan "Discard staged changes to a.txt" (rewrites the work tree)
      $ --literal-pathspecs restore --source=HEAD --staged --worktree -- a.txt
      status |D  d.txt
      status |A  new.txt
      status |MM p.txt
      a.txt: "one\n"
    confirm "Discard changes": Delete new.txt? It is new and only staged: its content is lost.
      plan "Discard staged changes to new.txt" (rewrites the work tree)
      $ --literal-pathspecs restore --source=HEAD --staged --worktree -- new.txt
      status |D  d.txt
      status |MM p.txt
      new.txt: (absent)
    confirm "Discard changes": Restore d.txt from HEAD? Its staged deletion is undone.
      plan "Discard staged changes to d.txt" (rewrites the work tree)
      $ --literal-pathspecs restore --source=HEAD --staged --worktree -- d.txt
      status |MM p.txt
      d.txt: "gone\n"
    |}]
;;

let%expect_test "hunks: stage one of two, unstage it, discard the other" =
  Fixture.with_repo (fun t ->
    let lines = List.init 12 ~f:(fun i -> sprintf "line %d\n" (i + 1)) in
    Fixture.write t "a.txt" (String.concat lines);
    commit t "base";
    Fixture.write
      t
      "a.txt"
      (String.concat
         (List.mapi lines ~f:(fun i line ->
            if i = 1 then "LINE 2\n" else if i = 10 then "LINE 11\n" else line)));
    let s = snapshot t in
    act ~snapshot:s t (Stage (hunk t s (Unstaged [ "a.txt" ]) ~path:"a.txt" 0));
    cached t;
    let s = snapshot t in
    act ~snapshot:s t (Unstage (hunk t s (Staged [ "a.txt" ]) ~path:"a.txt" 0));
    cached t;
    let s = snapshot t in
    act ~snapshot:s t (Discard (hunk t s (Unstaged [ "a.txt" ]) ~path:"a.txt" 1));
    contents t "a.txt";
    (* A staged hunk discarded: gone from the index and the work tree. *)
    let s = snapshot t in
    act ~snapshot:s t (Stage (hunk t s (Unstaged [ "a.txt" ]) ~path:"a.txt" 0));
    let s = snapshot t in
    act ~snapshot:s t (Discard (hunk t s (Staged [ "a.txt" ]) ~path:"a.txt" 0));
    contents t "a.txt");
  [%expect
    {|
    run
      plan "Stage hunk 1/2 of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |MM a.txt
      cached |--- a/a.txt
      cached |+++ b/a.txt
      cached |@@ -2 +2 @@ line 1
      cached |-line 2
      cached |+LINE 2
    run
      plan "Unstage hunk 1/1 of a.txt"
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn < patch
      status | M a.txt
    confirm "Discard hunk": Discard hunk 2/2 of a.txt? Its unstaged lines are lost.
      plan "Discard hunk 2/2 of a.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --reverse --whitespace=nowarn < patch
      status | M a.txt
      a.txt: "line 1\nLINE 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\nline 11\nline 12\n"
    run
      plan "Stage hunk 1/1 of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |M  a.txt
    confirm "Discard hunk": Discard staged hunk 1/1 of a.txt? It is removed from the index and the work tree and lost.
      plan "Discard staged hunk 1/1 of a.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn < patch
      a.txt: "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\nline 11\nline 12\n"
    |}]
;;

let%expect_test "a stale hunk fails its check and nothing is applied" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "one\ntwo\nthree\n";
    commit t "base";
    Fixture.write t "a.txt" "one\nTWO\nthree\n";
    let s = snapshot t in
    let stale = hunk t s (Unstaged [ "a.txt" ]) ~path:"a.txt" 0 in
    (* Changed since the diff (and staged meanwhile): the hunk no longer applies. *)
    Fixture.write t "a.txt" "one\n2\nthree\n";
    git t [ "add"; "a.txt" ];
    act ~snapshot:s t (Stage stale);
    cached t;
    act ~snapshot:s t (Discard stale);
    contents t "a.txt");
  [%expect
    {|
    run
      plan "Stage hunk 1/1 of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      failed: exit 1: error: patch failed: a.txt:1 / error: a.txt: patch does not apply
      (skipped)
      status |M  a.txt
      cached |--- a/a.txt
      cached |+++ b/a.txt
      cached |@@ -2 +2 @@ one
      cached |-two
      cached |+2
    confirm "Discard hunk": Discard hunk 1/1 of a.txt? Its unstaged lines are lost.
      plan "Discard hunk 1/1 of a.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --reverse --whitespace=nowarn < patch
      failed: exit 1: error: patch failed: a.txt:1 / error: a.txt: patch does not apply
      (skipped)
      status |M  a.txt
      a.txt: "one\n2\nthree\n"
    |}]
;;

let%expect_test "apply.whitespace=error does not block a line with trailing whitespace" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "one\n";
    commit t "base";
    git t [ "config"; "apply.whitespace"; "error" ];
    Fixture.write t "a.txt" "one\ntrailing \t\n";
    let s = snapshot t in
    act ~snapshot:s t (Stage (hunk t s (Unstaged [ "a.txt" ]) ~path:"a.txt" 0));
    printf "  index: %S\n" (Fixture.git t [ "show"; ":a.txt" ]));
  [%expect
    {|
    run
      plan "Stage hunk 1/1 of a.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |M  a.txt
      index: "one\ntrailing \t\n"
    |}]
;;

let%expect_test "a glob-like name only touches itself" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a*.txt" "star\n";
    Fixture.write t "ab.txt" "ab\n";
    commit t "base";
    Fixture.write t "a*.txt" "STAR\n";
    Fixture.write t "ab.txt" "AB\n";
    (* The diff panel's read is literal too. *)
    let s = snapshot t in
    List.iter (diff t s (Unstaged [ "a*.txt" ])).files ~f:(fun file ->
      printf "diff of a*.txt shows %s\n" (Diff.File.path file));
    act t (Stage (file Unstaged "a*.txt"));
    act t (Unstage (file Staged "a*.txt"));
    let s = snapshot t in
    act ~snapshot:s t (Stage (hunk t s (Unstaged [ "a*.txt" ]) ~path:"a*.txt" 0));
    act t (Discard (file Staged "a*.txt"));
    act t (Discard (file Unstaged "ab.txt"));
    contents t "a*.txt";
    contents t "ab.txt";
    Fixture.write t "a?.txt" "new\n";
    Fixture.write t "aq.txt" "new\n";
    act t (Discard (file Untracked "a?.txt"));
    act t (Stage (file Untracked "aq.txt")));
  [%expect
    {|
    diff of a*.txt shows a*.txt
    run
      plan "Stage a*.txt"
      $ --literal-pathspecs add --all -- 'a*.txt'
      status |M  a*.txt
      status | M ab.txt
    run
      plan "Unstage a*.txt"
      $ --literal-pathspecs restore --staged -- 'a*.txt'
      status | M a*.txt
      status | M ab.txt
    run
      plan "Stage hunk 1/1 of a*.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |M  a*.txt
      status | M ab.txt
    confirm "Discard changes": Discard the staged changes to a*.txt? They are lost: it returns to HEAD in the index and the work tree.
      plan "Discard staged changes to a*.txt" (rewrites the work tree)
      $ --literal-pathspecs restore --source=HEAD --staged --worktree -- 'a*.txt'
      status | M ab.txt
    confirm "Discard changes": Discard the unstaged changes to ab.txt? They are lost; staged changes are kept.
      plan "Discard unstaged changes to ab.txt" (rewrites the work tree)
      $ --literal-pathspecs restore --worktree -- ab.txt
      a*.txt: "star\n"
      ab.txt: "ab\n"
    confirm "Delete untracked file": Delete a?.txt? It is not in git and cannot be recovered.
      plan "Delete a?.txt" (rewrites the work tree)
      $ --literal-pathspecs clean --force --quiet -- 'a?.txt'
      status |?? aq.txt
    run
      plan "Stage aq.txt"
      $ --literal-pathspecs add --all -- aq.txt
      status |A  aq.txt
    |}]
;;

let%expect_test "unborn branch: reset and rm instead of restore" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\n";
    Fixture.write t "b.txt" "b\n";
    act t (Stage (file Untracked "a.txt"));
    act t (Unstage (file Staged "a.txt"));
    act t Stage_all;
    act t Unstage_all;
    act t (Stage (Section Untracked));
    let s = snapshot t in
    act ~snapshot:s t (Unstage (hunk t s (Staged [ "a.txt" ]) ~path:"a.txt" 0));
    act t (Discard (file Staged "b.txt"));
    contents t "b.txt";
    act t (Stage (file Untracked "a.txt"));
    act t (Discard (Section Staged)));
  [%expect
    {|
    run
      plan "Stage a.txt"
      $ --literal-pathspecs add --all -- a.txt
      status |A  a.txt
      status |?? b.txt
    run
      plan "Unstage a.txt"
      $ --literal-pathspecs reset --quiet -- a.txt
      status |?? a.txt
      status |?? b.txt
    run
      plan "Stage all changes (2 files)"
      $ --literal-pathspecs add --all -- a.txt b.txt
      status |A  a.txt
      status |A  b.txt
    run
      plan "Unstage all changes (2 files)"
      $ --literal-pathspecs reset --quiet -- a.txt b.txt
      status |?? a.txt
      status |?? b.txt
    run
      plan "Stage untracked files (2 files)"
      $ --literal-pathspecs add --all -- a.txt b.txt
      status |A  a.txt
      status |A  b.txt
    run
      plan "Unstage hunk 1/1 of a.txt"
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn < patch
      status |A  b.txt
      status |?? a.txt
    confirm "Discard changes": Delete b.txt? It is new and only staged: its content is lost.
      plan "Discard staged changes to b.txt" (rewrites the work tree)
      $ --literal-pathspecs rm --force --quiet -- b.txt
      status |?? a.txt
      b.txt: (absent)
    run
      plan "Stage a.txt"
      $ --literal-pathspecs add --all -- a.txt
      status |A  a.txt
    confirm "Discard changes": Discard the staged changes to 1 file? They are lost: the files return to HEAD in the index and the work tree (new files are deleted).
      plan "Discard staged changes (1 file)" (rewrites the work tree)
      $ --literal-pathspecs rm --force --quiet -- a.txt
    |}]
;;

let%expect_test "new, deleted and no-newline files by hunk" =
  Fixture.with_repo (fun t ->
    Fixture.write t "del.txt" "gone\n";
    Fixture.write t "nonl.txt" "last";
    commit t "base";
    Fixture.write t "new.txt" "new\n";
    git t [ "add"; "new.txt" ];
    Core_unix.unlink (Fixture.path t "del.txt");
    Fixture.write t "nonl.txt" "last\nmore";
    let s = snapshot t in
    act ~snapshot:s t (Unstage (hunk t s (Staged [ "new.txt" ]) ~path:"new.txt" 0));
    let s = snapshot t in
    act ~snapshot:s t (Stage (hunk t s (Unstaged [ "del.txt" ]) ~path:"del.txt" 0));
    act ~snapshot:s t (Stage (hunk t s (Unstaged [ "nonl.txt" ]) ~path:"nonl.txt" 0));
    cached t;
    let s = snapshot t in
    act ~snapshot:s t (Unstage (hunk t s (Staged [ "nonl.txt" ]) ~path:"nonl.txt" 0));
    act ~snapshot:s t (Discard (hunk t s (Staged [ "del.txt" ]) ~path:"del.txt" 0));
    contents t "del.txt";
    let s = snapshot t in
    act ~snapshot:s t (Discard (hunk t s (Unstaged [ "nonl.txt" ]) ~path:"nonl.txt" 0));
    contents t "nonl.txt";
    (* An untracked file's hunk acts on the whole file. *)
    let s = snapshot t in
    act ~snapshot:s t (Stage (hunk t s (Untracked "new.txt") ~path:"new.txt" 0));
    git t [ "reset"; "-q"; "new.txt" ];
    let s = snapshot t in
    let untracked = hunk t s (Untracked "new.txt") ~path:"new.txt" 0 in
    act ~snapshot:s t (Unstage untracked);
    act ~snapshot:s t (Discard untracked));
  [%expect
    {|
    run
      plan "Unstage hunk 1/1 of new.txt"
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn < patch
      status | D del.txt
      status | M nonl.txt
      status |?? new.txt
    run
      plan "Stage hunk 1/1 of del.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |D  del.txt
      status | M nonl.txt
      status |?? new.txt
    run
      plan "Stage hunk 1/1 of nonl.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |D  del.txt
      status |M  nonl.txt
      status |?? new.txt
      cached |deleted file mode 100644
      cached |--- a/del.txt
      cached |+++ /dev/null
      cached |@@ -1 +0,0 @@
      cached |-gone
      cached |--- a/nonl.txt
      cached |+++ b/nonl.txt
      cached |@@ -1 +1,2 @@
      cached |-last
      cached |+last
      cached |+more
    run
      plan "Unstage hunk 1/1 of nonl.txt"
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn < patch
      status |D  del.txt
      status | M nonl.txt
      status |?? new.txt
    confirm "Discard hunk": Discard staged hunk 1/1 of del.txt? It is removed from the index and the work tree and lost.
      plan "Discard staged hunk 1/1 of del.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --index --reverse --whitespace=nowarn < patch
      status | M nonl.txt
      status |?? new.txt
      del.txt: "gone\n"
    confirm "Discard hunk": Discard hunk 1/1 of nonl.txt? Its unstaged lines are lost.
      plan "Discard hunk 1/1 of nonl.txt" (rewrites the work tree)
      $ --literal-pathspecs apply --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --reverse --whitespace=nowarn < patch
      status |?? new.txt
      nonl.txt: "last"
    run
      plan "Stage new.txt"
      $ --literal-pathspecs add --all -- new.txt
      status |A  new.txt
    refused: new.txt is not staged; nothing ran
    confirm "Delete untracked file": Delete new.txt? It is not in git and cannot be recovered.
      plan "Delete new.txt" (rewrites the work tree)
      $ --literal-pathspecs clean --force --quiet -- new.txt
    |}]
;;

let%expect_test "a rename: unstage, a hunk keeps it, discard undoes it" =
  Fixture.with_repo (fun t ->
    Fixture.write t "old name.txt" "alpha\nbeta\ngamma\ndelta\nepsilon\n";
    commit t "base";
    git t [ "mv"; "old name.txt"; "new \195\169.txt" ];
    Fixture.write t "new \195\169.txt" "alpha\nbeta\ngamma\ndelta\nEPSILON\n";
    git t [ "add"; "new \195\169.txt" ];
    status t;
    let s = snapshot t in
    act
      ~snapshot:s
      t
      (Unstage
         (hunk
            t
            s
            (Staged [ "old name.txt"; "new \195\169.txt" ])
            ~path:"new \195\169.txt"
            0));
    cached t;
    act t (Unstage (file Staged "new \195\169.txt"));
    git t [ "add"; "--all" ];
    status t;
    act t (Discard (file Staged "new \195\169.txt"));
    contents t "old name.txt";
    contents t "new \195\169.txt");
  [%expect
    {|
      status |R  "old name.txt" -> "new \303\251.txt"
    run
      plan "Unstage hunk 1/1 of new \195\169.txt"
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --reverse --whitespace=nowarn < patch
      status |RM "old name.txt" -> "new \303\251.txt"
      cached |rename from old name.txt
      cached |rename to "new \303\251.txt"
    run
      plan "Unstage new \195\169.txt"
      $ --literal-pathspecs restore --staged -- 'old name.txt' 'new é.txt'
      status | D "old name.txt"
      status |?? "new \303\251.txt"
      status |R  "old name.txt" -> "new \303\251.txt"
    confirm "Discard changes": Undo the rename of old name.txt to new é.txt? new é.txt is deleted with its staged changes and old name.txt is restored from HEAD.
      plan "Discard staged changes to new \195\169.txt" (rewrites the work tree)
      $ --literal-pathspecs restore --source=HEAD --staged --worktree -- 'old name.txt' 'new é.txt'
      old name.txt: "alpha\nbeta\ngamma\ndelta\nepsilon\n"
      new é.txt: (absent)
    |}]
;;

let%expect_test "conflicts: s marks resolved; u, x and hunks refused; S leaves them out" =
  Fixture.with_repo (fun t ->
    Fixture.write t "uu.txt" "base\n";
    Fixture.write t "dd.txt" "base\n";
    commit t "base";
    git t [ "checkout"; "-q"; "-b"; "other" ];
    Fixture.write t "uu.txt" "theirs\n";
    git t [ "mv"; "dd.txt"; "dd-other.txt" ];
    commit t "other";
    git t [ "checkout"; "-q"; "main" ];
    Fixture.write t "uu.txt" "ours\n";
    git t [ "mv"; "dd.txt"; "dd-main.txt" ];
    commit t "main";
    ignore
      (Fixture.run
         t
         (Exec.Spec.create ~kind:Mutate ~cwd:t.work "git" [ "merge"; "-q"; "other" ])
       : Exec.Result.t);
    Fixture.write t "loose.txt" "loose\n";
    status t;
    let s = snapshot t in
    act ~snapshot:s t (Unstage (file Conflicted "uu.txt"));
    act ~snapshot:s t (Discard (file Conflicted "uu.txt"));
    act ~snapshot:s t (Unstage (Section Conflicted));
    act ~snapshot:s t (Discard (Section Conflicted));
    act ~snapshot:s t (Stage (hunk t s (Conflicted [ "uu.txt" ]) ~path:"uu.txt" 0));
    act ~snapshot:s t (Discard (hunk t s (Conflicted [ "uu.txt" ]) ~path:"uu.txt" 0));
    act ~snapshot:s t Stage_all;
    act t (Stage (file Conflicted "dd.txt"));
    act t (Stage (Section Conflicted)));
  [%expect
    {|
      status |AU dd-main.txt
      status |UA dd-other.txt
      status |DD dd.txt
      status |UU uu.txt
      status |?? loose.txt
    refused: uu.txt is conflicted: conflict resolution is not supported yet; resolve it in the editor, then stage it (s) to mark it resolved; nothing ran
    refused: uu.txt is conflicted: conflict resolution is not supported yet; resolve it in the editor, then stage it (s) to mark it resolved; nothing ran
    refused: Conflict resolution is not supported yet; nothing ran
    refused: Conflict resolution is not supported yet; nothing ran
    refused: uu.txt is conflicted: conflict resolution is not supported yet; resolve it in the editor, then stage it (s) to mark it resolved; nothing ran
    refused: uu.txt is conflicted: conflict resolution is not supported yet; resolve it in the editor, then stage it (s) to mark it resolved; nothing ran
    run
      plan "Stage all changes (1 file)"
      $ --literal-pathspecs add --all -- loose.txt
      status |AU dd-main.txt
      status |UA dd-other.txt
      status |DD dd.txt
      status |A  loose.txt
      status |UU uu.txt
    run
      plan "Mark dd.txt resolved"
      $ --literal-pathspecs add --all -- dd.txt
      status |AU dd-main.txt
      status |UA dd-other.txt
      status |A  loose.txt
      status |UU uu.txt
    run
      plan "Mark 3 files resolved"
      $ --literal-pathspecs add --all -- dd-main.txt dd-other.txt uu.txt
      status |A  dd-other.txt
      status |A  loose.txt
      status |M  uu.txt
    |}]
;;

let%expect_test "intent-to-add: not discarded, its hunk stages" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\n";
    commit t "base";
    Fixture.write t "ita.txt" "content\n";
    git t [ "add"; "-N"; "ita.txt" ];
    Fixture.write t "a.txt" "A\n";
    status t;
    let s = snapshot t in
    act ~snapshot:s t (Discard (file Unstaged "ita.txt"));
    act ~snapshot:s t (Discard (hunk t s (Unstaged [ "ita.txt" ]) ~path:"ita.txt" 0));
    act ~snapshot:s t (Discard (Section Unstaged));
    act t (Stage (hunk t s (Unstaged [ "ita.txt" ]) ~path:"ita.txt" 0));
    cached t;
    contents t "ita.txt";
    git t [ "reset"; "-q" ];
    git t [ "add"; "-N"; "ita.txt" ];
    git t [ "checkout"; "-q"; "--"; "a.txt" ];
    act t (Discard (Section Unstaged)));
  [%expect
    {|
      status | M a.txt
      status | A ita.txt
    refused: ita.txt is intent-to-add (git add -N): discarding would empty it; nothing ran
    refused: ita.txt is intent-to-add (git add -N): discarding would empty it; nothing ran
    confirm "Discard changes": Discard the unstaged changes to 1 file? They are lost; staged changes are kept. Left out: ita.txt (intent-to-add).
      plan "Discard unstaged changes (1 file) (left out: ita.txt)" (rewrites the work tree)
      $ --literal-pathspecs restore --worktree -- a.txt
      status | A ita.txt
    run
      plan "Stage hunk 1/1 of ita.txt"
      $ --literal-pathspecs apply --cached --whitespace=nowarn --check < patch
      $ --literal-pathspecs apply --cached --whitespace=nowarn < patch
      status |A  ita.txt
      cached |new file mode 100644
      cached |--- /dev/null
      cached |+++ b/ita.txt
      cached |@@ -0,0 +1 @@
      cached |+content
      ita.txt: "content\n"
    refused: ita.txt is intent-to-add (git add -N): discarding would empty it; nothing ran
    |}]
;;

let%expect_test "untracked files and a nested repository" =
  Fixture.with_repo (fun t ->
    Fixture.write t "top.txt" "top\n";
    commit t "base";
    git t [ "init"; "-q"; "nested" ];
    Fixture.write t "dir/\195\188 file.txt" "x\n";
    Fixture.write t "loose.txt" "loose\n";
    status t;
    let s = snapshot t in
    act ~snapshot:s t (Stage (file Untracked "nested/"));
    act ~snapshot:s t (Discard (file Untracked "nested/"));
    act ~snapshot:s t (Discard (file Untracked "dir/\195\188 file.txt"));
    act t (Discard (Section Untracked));
    Fixture.write t "loose.txt" "loose\n";
    act t Stage_all;
    git t [ "reset"; "-q" ];
    act t (Stage (Section Untracked));
    git t [ "commit"; "-q"; "-m"; "loose" ];
    (* Only the nested repository is left. *)
    let s = snapshot t in
    act ~snapshot:s t (Stage (Section Untracked));
    act ~snapshot:s t (Discard (Section Untracked));
    act ~snapshot:s t Stage_all);
  [%expect
    {|
      status |?? "dir/\303\274 file.txt"
      status |?? loose.txt
      status |?? nested/
    refused: nested/ is a nested repository: Ches does not stage it; nothing ran
    refused: nested/ is a nested repository: delete it outside Ches; nothing ran
    confirm "Delete untracked file": Delete dir/ü file.txt? It is not in git and cannot be recovered.
      plan "Delete dir/\195\188 file.txt" (rewrites the work tree)
      $ --literal-pathspecs clean --force --quiet -- 'dir/ü file.txt'
      status |?? loose.txt
      status |?? nested/
    confirm "Delete untracked files": Delete 1 untracked file? They are not in git and cannot be recovered. Left out: nested/ (nested repository).
      plan "Delete untracked files (1 file) (left out: nested/)" (rewrites the work tree)
      $ --literal-pathspecs clean --force --quiet -- loose.txt
      status |?? nested/
    run
      plan "Stage all changes (1 file) (left out: nested/)"
      $ --literal-pathspecs add --all -- loose.txt
      status |A  loose.txt
      status |?? nested/
    run
      plan "Stage untracked files (1 file) (left out: nested/)"
      $ --literal-pathspecs add --all -- loose.txt
      status |A  loose.txt
      status |?? nested/
    refused: nested/ is a nested repository: Ches does not stage it; nothing ran
    refused: nested/ is a nested repository: delete it outside Ches; nothing ran
    refused: nested/ is a nested repository: Ches does not stage it; nothing ran
    |}]
;;

let%expect_test "binary, mode-only, rename-only and submodule files: whole-file actions" =
  Fixture.with_repo (fun t ->
    Fixture.write t "bin.dat" "\000\001\002";
    Fixture.write t "mode.sh" "echo\n";
    Fixture.write t "same.txt" "same\n";
    commit t "base";
    git t [ "init"; "-q"; "sub" ];
    Fixture.write t "sub/s.txt" "s\n";
    ignore (Fixture.git ~cwd:(Fixture.path t "sub") t [ "add"; "." ] : string);
    ignore
      (Fixture.git ~cwd:(Fixture.path t "sub") t [ "commit"; "-q"; "-m"; "s" ] : string);
    git t [ "add"; "sub" ];
    commit t "sub";
    Fixture.write t "bin.dat" "\000\001\003";
    git t [ "update-index"; "--chmod=+x"; "mode.sh" ];
    Core_unix.chmod (Fixture.path t "mode.sh") ~perm:0o755;
    git t [ "mv"; "same.txt"; "moved.txt" ];
    Fixture.write t "sub/s.txt" "s2\n";
    ignore
      (Fixture.git ~cwd:(Fixture.path t "sub") t [ "commit"; "-q"; "-am"; "s2" ] : string);
    status t;
    let s = snapshot t in
    act ~snapshot:s t (Stage (hunk t s (Unstaged [ "bin.dat" ]) ~path:"bin.dat" 0));
    act ~snapshot:s t (Unstage (hunk t s (Staged [ "mode.sh" ]) ~path:"mode.sh" 0));
    act
      ~snapshot:s
      t
      (Unstage (hunk t s (Staged [ "same.txt"; "moved.txt" ]) ~path:"moved.txt" 0));
    act ~snapshot:s t (Stage (hunk t s (Unstaged [ "sub" ]) ~path:"sub" 0));
    act ~snapshot:s t (Discard (file Unstaged "sub"));
    (* In the diff, s u x on such a file's header act on the whole file. *)
    act ~snapshot:s t (Stage (file Unstaged "bin.dat"));
    act t (Discard (Section Unstaged));
    act t (Unstage (file Staged "mode.sh"));
    act t (Stage (file Unstaged "sub"));
    act t (Discard (Section Staged)));
  [%expect
    {|
      status | M bin.dat
      status |M  mode.sh
      status |R  same.txt -> moved.txt
      status | M sub
    refused: Hunk actions do not apply to bin.dat: it is binary
    refused: Hunk actions do not apply to mode.sh: only its mode changed
    refused: Hunk actions do not apply to moved.txt: it is only renamed
    refused: Hunk actions do not apply to sub: it is a submodule
    refused: sub is a submodule: discard is not supported; nothing ran
    run
      plan "Stage bin.dat"
      $ --literal-pathspecs add --all -- bin.dat
      status |M  bin.dat
      status |M  mode.sh
      status |R  same.txt -> moved.txt
      status | M sub
    refused: sub is a submodule: discard is not supported; nothing ran
    run
      plan "Unstage mode.sh"
      $ --literal-pathspecs restore --staged -- mode.sh
      status |M  bin.dat
      status | M mode.sh
      status |R  same.txt -> moved.txt
      status | M sub
    run
      plan "Stage sub"
      $ --literal-pathspecs add --all -- sub
      status |M  bin.dat
      status | M mode.sh
      status |R  same.txt -> moved.txt
      status |M  sub
    confirm "Discard changes": Discard the staged changes to 2 files? They are lost: the files return to HEAD in the index and the work tree (new files are deleted). Left out: sub (submodule).
      plan "Discard staged changes (2 files) (left out: sub)" (rewrites the work tree)
      $ --literal-pathspecs restore --source=HEAD --staged --worktree -- bin.dat same.txt moved.txt
      status | M mode.sh
      status |M  sub
    |}]
;;

let%expect_test "section texts, left-out entries, and every refusal" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a.txt" "a\n";
    Fixture.write t "b.txt" "b\n";
    Fixture.write t "c.txt" "c\n";
    Fixture.write t ".gitignore" "*.o\n";
    commit t "base";
    Fixture.write t "a.txt" "A\n";
    Fixture.write t "b.txt" "B\n";
    Fixture.write t "c.txt" "C\n";
    git t [ "add"; "b.txt"; "c.txt" ];
    Fixture.write t "b.txt" "B2\n";
    Fixture.write t "ita.txt" "ita\n";
    git t [ "add"; "-N"; "ita.txt" ];
    git t [ "init"; "-q"; "nested" ];
    Fixture.write t "u.txt" "u\n";
    Fixture.write t "x.o" "o\n";
    status t;
    let s = snapshot ~ignored:true t in
    List.iter
      [ B.Stage (Section Unstaged)
      ; Stage (Section Untracked)
      ; Unstage (Section Staged)
      ; Discard (Section Unstaged)
      ; Discard (Section Untracked)
      ; Discard (Section Staged)
      ; Stage_all
      ; Unstage_all
      ; Stage (file Staged "c.txt")
      ; Stage (Section Staged)
      ; Stage (hunk t s (Staged [ "c.txt" ]) ~path:"c.txt" 0)
      ; Unstage (file Unstaged "a.txt")
      ; Unstage (file Untracked "u.txt")
      ; Unstage (Section Unstaged)
      ; Unstage (hunk t s (Unstaged [ "a.txt" ]) ~path:"a.txt" 0)
      ; Stage (file Ignored "x.o")
      ; Discard (file Ignored "x.o")
      ; Unstage (file Ignored "x.o")
      ; Stage (Section Ignored)
      ; Discard (Section Ignored)
      ; Unstage (Section Ignored)
      ; Stage (file Unstaged "c.txt")
      ; Stage (file Untracked "gone.txt")
      ; Stage (Section Conflicted)
      ; Discard (Section Conflicted)
      ]
      ~f:(fun action -> ignore (decide s action : Ches_vcs.Backend.Plan.t option));
    git t [ "add"; "a.txt"; "b.txt"; "c.txt"; "ita.txt"; "u.txt" ];
    git t [ "commit"; "-q"; "-m"; "all" ];
    let s = snapshot t in
    ignore (decide s Stage_all : Ches_vcs.Backend.Plan.t option);
    ignore (decide s Unstage_all : Ches_vcs.Backend.Plan.t option);
    ignore (decide s (Stage (Section Unstaged)) : Ches_vcs.Backend.Plan.t option));
  [%expect
    {|
      status | M a.txt
      status |MM b.txt
      status |M  c.txt
      status | A ita.txt
      status |?? nested/
      status |?? u.txt
    run
      plan "Stage unstaged changes (3 files)"
      $ --literal-pathspecs add --all -- a.txt b.txt ita.txt
    run
      plan "Stage untracked files (1 file) (left out: nested/)"
      $ --literal-pathspecs add --all -- u.txt
    run
      plan "Unstage staged changes (2 files)"
      $ --literal-pathspecs restore --staged -- b.txt c.txt
    confirm "Discard changes": Discard the unstaged changes to 2 files? They are lost; staged changes are kept. Left out: ita.txt (intent-to-add).
      plan "Discard unstaged changes (2 files) (left out: ita.txt)" (rewrites the work tree)
      $ --literal-pathspecs restore --worktree -- a.txt b.txt
    confirm "Delete untracked files": Delete 1 untracked file? They are not in git and cannot be recovered. Left out: nested/ (nested repository).
      plan "Delete untracked files (1 file) (left out: nested/)" (rewrites the work tree)
      $ --literal-pathspecs clean --force --quiet -- u.txt
    confirm "Discard changes": Discard the staged changes to 1 file? They are lost: the files return to HEAD in the index and the work tree (new files are deleted). Left out: b.txt (also has unstaged changes).
      plan "Discard staged changes (1 file) (left out: b.txt)" (rewrites the work tree)
      $ --literal-pathspecs restore --source=HEAD --staged --worktree -- c.txt
    run
      plan "Stage all changes (4 files) (left out: nested/)"
      $ --literal-pathspecs add --all -- a.txt b.txt ita.txt u.txt
    run
      plan "Unstage all changes (2 files)"
      $ --literal-pathspecs restore --staged -- b.txt c.txt
    refused: c.txt is already staged; nothing ran
    refused: Already staged; nothing ran
    refused: c.txt is already staged; nothing ran
    refused: a.txt is not staged; nothing ran
    refused: u.txt is not staged; nothing ran
    refused: Nothing staged here; nothing ran
    refused: a.txt is not staged; nothing ran
    refused: x.o is ignored; nothing ran
    refused: x.o is ignored; nothing ran
    refused: x.o is not staged; nothing ran
    refused: Ignored files are not staged; nothing ran
    refused: Ignored files are not discarded; nothing ran
    refused: Nothing staged here; nothing ran
    refused: c.txt is no longer listed; refresh (g r); nothing ran
    refused: gone.txt is no longer listed; refresh (g r); nothing ran
    refused: Nothing here; nothing ran
    refused: Conflict resolution is not supported yet; nothing ran
    refused: nested/ is a nested repository: Ches does not stage it; nothing ran
    refused: Nothing staged; nothing ran
    refused: Nothing here; nothing ran
    |}]
;;
