(* Log scopes against real repositories (phase 8): each scope's read through
   Backend.refresh and snapshot, printed as the Commits panel's section title, then one
   row per commit (the graph as the view draws it, refs, subject), then any problems.
   Also the log popup (Log.popup, enabled, scope) as pure functions. Commit hashes are
   reproducible (fixed dates) but rows show subjects, which read better. *)

open! Core
open Ches_vcs
module Fixture = Ches_vcs_fixture.Fixture_repo
module Git = Ches_vcs_git
module B = Ches_vcs_git.Backend
module Log = Ches_vcs_git.Log

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

let snapshot t log =
  let refresh = { Backend.Refresh.default with log } in
  let repository = repository t in
  ok_exn
    (B.snapshot repository refresh (Fixture.run_steps t (B.refresh repository refresh)))
;;

(* The view's rows: the graph when the scope draws one (from first parents only with
   [first_parent]), then ["(<refs>) "] when any, then the subject. *)
let show t (log : Log_scope.t) =
  let s = snapshot t log in
  let commits =
    List.find_exn (B.panels s) ~f:(fun panel -> Panel.Id.equal panel.id B.commits_panel)
  in
  (match commits.sections with
   | [] -> print_endline "(no commits)"
   | sections ->
     List.iter sections ~f:(fun section -> print_endline section.title);
     let graph =
       if Log_scope.graph_shown log
       then
         Graph.rows
           (List.map s.commits ~f:(fun (commit : Log.Commit.t) ->
              let parents =
                if log.first_parent then List.take commit.parents 1 else commit.parents
              in
              commit.hash, parents))
       else List.map s.commits ~f:(const "")
     in
     List.iter2_exn graph s.commits ~f:(fun row (commit : Log.Commit.t) ->
       printf
         "  %s%s%s\n"
         row
         (match commit.refs with
          | [] -> ""
          | refs -> "(" ^ String.concat refs ~sep:", " ^ ") ")
         commit.subject));
  List.iter s.problems ~f:(fun problem -> printf "problem: %s\n" (relative t problem))
;;

let default = Log_scope.default

(* Commit with [GIT_COMMITTER_DATE] (and the author date) [minutes] after the fixture's
   fixed date. *)
let commit_dated (t : Fixture.t) message ~minutes =
  git t [ "add"; "-A" ];
  let spec = Git.Cli.mutate ~cwd:t.work [ "commit"; "-q"; "-m"; message ] in
  let date = sprintf "%d +0000" (1767225600 + (60 * minutes)) in
  let result =
    Fixture.run
      t
      { spec with env = [ "GIT_COMMITTER_DATE", date; "GIT_AUTHOR_DATE", date ] }
  in
  if not (Exec.Result.succeeded result) then failwith result.stderr
;;

(* main: one, two (tag v1, annotated v2 on it), pushed to origin; dev from one with
   "dev work"; origin/topic pushed from dev; then "dev more" on dev only and "main
   three" on main. *)
let branches (t : Fixture.t) =
  Fixture.write t "f.txt" "one\n";
  commit t "one";
  git t [ "branch"; "dev" ];
  Fixture.write t "f.txt" "one\ntwo\n";
  commit t "two";
  git t [ "tag"; "v1" ];
  git t [ "tag"; "-a"; "v2"; "-m"; "annotated" ];
  git t [ "push"; "-q"; "origin"; "main" ];
  git t [ "switch"; "-q"; "dev" ];
  Fixture.write t "d.txt" "dev\n";
  commit t "dev work";
  git t [ "push"; "-q"; "origin"; "dev:topic" ];
  Fixture.write t "d.txt" "dev\nmore\n";
  commit t "dev more";
  git t [ "switch"; "-q"; "main" ];
  Fixture.write t "f.txt" "one\ntwo\nthree\n";
  commit t "main three"
;;

let%expect_test "HEAD, a branch, all branches; refs; the section title" =
  Fixture.with_repo ~remote:true (fun t ->
    branches t;
    show t default;
    show t { default with range = Branch "dev" };
    show t { default with range = All };
    (* The limit: as many commits as asked for says "first <n>". *)
    show t { default with limit = 2 };
    show t { default with range = All; limit = 5 });
  [%expect
    {|
    Recent commits
      ● (HEAD -> main) main three
      ● (tag: v2, tag: v1, origin/main) two
      ● one
    Commits on dev
      ● (dev) dev more
      ● (origin/topic) dev work
      ● one
    All branches
      ● (dev) dev more
      ● (origin/topic) dev work
      │ ● (HEAD -> main) main three
      │ ● (tag: v2, tag: v1, origin/main) two
      ●─╯ one
    Recent commits (first 2)
      ● (HEAD -> main) main three
      ● (tag: v2, tag: v1, origin/main) two
    All branches (first 5)
      ● (dev) dev more
      ● (origin/topic) dev work
      │ ● (HEAD -> main) main three
      │ ● (tag: v2, tag: v1, origin/main) two
      ●─╯ one
    |}]
;;

let%expect_test "All with a detached HEAD: its commits, and HEAD without an arrow" =
  Fixture.with_repo ~remote:true (fun t ->
    branches t;
    git t [ "switch"; "-q"; "--detach"; "v1" ];
    Fixture.write t "x.txt" "detached\n";
    commit t "detached work";
    show t { default with range = All };
    show t default);
  [%expect
    {|
    All branches
      ● (dev) dev more
      ● (origin/topic) dev work
      │ ● (main) main three
      │ │ ● (HEAD) detached work
      │ ●─╯ (tag: v2, tag: v1, origin/main) two
      ●─╯ one
    Recent commits
      ● (HEAD) detached work
      ● (tag: v2, tag: v1, origin/main) two
      ● one
    |}]
;;

(* main: base, "main x"; side from base: "side 1", "side 2"; merged into main with
   --no-ff; then "after". *)
let merged (t : Fixture.t) =
  Fixture.write t "f.txt" "base\n";
  commit t "base";
  git t [ "switch"; "-q"; "-c"; "side" ];
  Fixture.write t "s.txt" "1\n";
  commit t "side 1";
  Fixture.write t "s.txt" "1\n2\n";
  commit t "side 2";
  git t [ "switch"; "-q"; "main" ];
  Fixture.write t "m.txt" "x\n";
  commit t "main x";
  git t [ "merge"; "-q"; "--no-ff"; "-m"; "merge side"; "side" ];
  Fixture.write t "m.txt" "x\nafter\n";
  commit t "after"
;;

let%expect_test "merges: the graph, --no-merges, --first-parent, both" =
  Fixture.with_repo (fun t ->
    merged t;
    show t default;
    show t { default with merges = false };
    show t { default with first_parent = true };
    show t { default with merges = false; first_parent = true };
    (* The graph switch off (and above, merges omitted): no graph and no --topo-order,
       so git's date order, which at equal dates lists base before "side 1". *)
    show t { default with graph = false });
  [%expect
    {|
    Recent commits
      ● (HEAD -> main) after
      ●─╮ merge side
      │ ● (side) side 2
      │ ● side 1
      ● │ main x
      ●─╯ base
    Recent commits (no merges)
      (HEAD -> main) after
      main x
      (side) side 2
      base
      side 1
    Recent commits (first parent)
      ● (HEAD -> main) after
      ● merge side
      ● main x
      ● base
    Recent commits (no merges, first parent)
      (HEAD -> main) after
      main x
      base
    Recent commits
      (HEAD -> main) after
      merge side
      main x
      (side) side 2
      base
      side 1
    |}]
;;

let%expect_test "--topo-order keeps parents after children when dates are out of order" =
  Fixture.with_repo (fun t ->
    (* In minutes: base 10; main: "main x" 50; side: "side 1" 40, "side 2" 5 (older
       than its parent); merged at 60. By date, base comes before side's commits. *)
    Fixture.write t "f.txt" "base\n";
    commit_dated t "base" ~minutes:10;
    git t [ "switch"; "-q"; "-c"; "side" ];
    Fixture.write t "s.txt" "1\n";
    commit_dated t "side 1" ~minutes:40;
    Fixture.write t "s.txt" "1\n2\n";
    commit_dated t "side 2" ~minutes:5;
    git t [ "switch"; "-q"; "main" ];
    Fixture.write t "m.txt" "x\n";
    commit_dated t "main x" ~minutes:50;
    git t [ "merge"; "-q"; "--no-ff"; "--no-commit"; "side" ];
    commit_dated t "merge side" ~minutes:60;
    show t default;
    show t { default with graph = false });
  [%expect
    {|
    Recent commits
      ●─╮ (HEAD -> main) merge side
      │ ● (side) side 2
      │ ● side 1
      ● │ main x
      ●─╯ base
    Recent commits
      (HEAD -> main) merge side
      main x
      base
      (side) side 2
      side 1
    |}]
;;

let%expect_test "file history follows a rename (--follow)" =
  Fixture.with_repo (fun t ->
    Fixture.write t "old.txt" "one\n";
    commit t "add old";
    Fixture.write t "old.txt" "one\ntwo\n";
    commit t "edit old";
    Fixture.write t "unrelated.txt" "u\n";
    commit t "unrelated";
    git t [ "mv"; "old.txt"; "new.txt" ];
    commit t "rename to new";
    git t [ "switch"; "-q"; "-c"; "side" ];
    Fixture.write t "new.txt" "one\ntwo\nside\n";
    commit t "side edits new";
    git t [ "switch"; "-q"; "main" ];
    Fixture.write t "other.txt" "x\n";
    commit t "other";
    git t [ "merge"; "-q"; "--no-ff"; "-m"; "merge side"; "side" ];
    Fixture.write t "new.txt" "one\ntwo\nside\nthree\n";
    commit t "edit new";
    let history = { default with path = Some "new.txt" } in
    show t history;
    (* git 2.43: --follow combines with --first-parent (the merge shows: its diff
       against its first parent changes the file) and with --no-merges. *)
    show t { history with first_parent = true };
    show t { history with merges = false };
    show t { history with merges = false; first_parent = true };
    (* The old name alone: its own history, which ends at the rename. *)
    show t { default with path = Some "old.txt" };
    show t { history with limit = 2 };
    (* The range still applies. *)
    show t { history with range = Branch "side" };
    show t { history with range = All });
  [%expect
    {|
    History of new.txt
      (HEAD -> main) edit new
      (side) side edits new
      rename to new
      edit old
      add old
    History of new.txt (first parent)
      (HEAD -> main) edit new
      merge side
      rename to new
      edit old
      add old
    History of new.txt (no merges)
      (HEAD -> main) edit new
      (side) side edits new
      rename to new
      edit old
      add old
    History of new.txt (no merges, first parent)
      (HEAD -> main) edit new
      rename to new
      edit old
      add old
    History of old.txt
      rename to new
      edit old
      add old
    History of new.txt (first 2)
      (HEAD -> main) edit new
      (side) side edits new
    History of new.txt
      (side) side edits new
      rename to new
      edit old
      add old
    History of new.txt
      (HEAD -> main) edit new
      (side) side edits new
      rename to new
      edit old
      add old
    |}]
;;

let%expect_test "--follow across a rename made on a merged branch misses the old name's \
                 edits on the other side"
  =
  (* git 2.43's --follow tracks one name for the whole walk: once it passes the rename
     it looks for the old name everywhere, and before that the new name everywhere. *)
  Fixture.with_repo (fun t ->
    Fixture.write t "old.txt" "one\n";
    commit t "add old";
    git t [ "switch"; "-q"; "-c"; "side" ];
    git t [ "mv"; "old.txt"; "new.txt" ];
    commit t "side renames to new";
    git t [ "switch"; "-q"; "main" ];
    Fixture.write t "old.txt" "one\nmain\n";
    commit t "main edits old";
    git t [ "merge"; "-q"; "--no-ff"; "-m"; "merge side"; "side" ];
    show t { default with path = Some "new.txt" };
    show t { default with path = Some "new.txt"; first_parent = true });
  [%expect
    {|
    History of new.txt
      (side) side renames to new
      add old
    History of new.txt (first parent)
      (HEAD -> main) merge side
      main edits old
      add old
    |}]
;;

let%expect_test "a path with glob characters is literal" =
  Fixture.with_repo (fun t ->
    Fixture.write t "a*.txt" "star\n";
    Fixture.write t "ab.txt" "b\n";
    commit t "both";
    Fixture.write t "ab.txt" "b\nb\n";
    commit t "ab only";
    Fixture.write t "a*.txt" "star\nstar\n";
    commit t "star only";
    Fixture.write t "ac.txt" "c\n";
    commit t "ac";
    show t { default with path = Some "a*.txt" };
    show t { default with path = Some "ab.txt" };
    (* A pattern matching ab.txt and ac.txt matches no file of that name. *)
    show t { default with path = Some "a?.txt" });
  [%expect
    {|
    History of a*.txt
      star only
      both
    History of ab.txt
      ab only
      both
    (no commits)
    |}]
;;

let%expect_test "an unborn branch: no commits and no problem" =
  Fixture.with_repo (fun t ->
    show t default;
    show t { default with range = All };
    show t { default with path = Some "f.txt" };
    Fixture.write t "f.txt" "staged\n";
    git t [ "add"; "f.txt" ];
    show t default);
  [%expect
    {|
    (no commits)
    (no commits)
    (no commits)
    (no commits)
    |}]
;;

let%expect_test "a deleted branch: no commits, and a problem" =
  Fixture.with_repo (fun t ->
    Fixture.write t "f.txt" "one\n";
    commit t "one";
    git t [ "branch"; "gone" ];
    git t [ "branch"; "-q"; "-D"; "gone" ];
    show t { default with range = Branch "gone" };
    (* A branch name that looks like an option is still a revision. *)
    show t { default with range = Branch "--all" });
  [%expect
    {|
    (no commits)
    problem: git --no-pager -c color.ui=false -c core.quotepath=false --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=200 --topo-order --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s --end-of-options refs/heads/gone --: exit 128: fatal: bad revision 'refs/heads/gone'
    (no commits)
    problem: git --no-pager -c color.ui=false -c core.quotepath=false --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=200 --topo-order --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s --end-of-options refs/heads/--all --: exit 128: fatal: bad revision 'refs/heads/--all'
    |}]
;;

(* The log popup, as pure functions. *)

let print_popup (popup : _ Popup.t) =
  print_endline popup.title;
  List.iter (Popup.help popup) ~f:(fun (key, description) ->
    printf "  %s  %s\n" key description)
;;

let%expect_test "the popup: switches and actions, with and without a branch and file" =
  print_popup (Log.popup ~branch:(Some "dev") ~file:(Some "src/a b.ml"));
  print_popup (Log.popup ~branch:None ~file:None);
  print_s [%sexp (Log.flags : string list)];
  [%expect
    {|
    Log
      -g  Show the graph (--graph)
      -m  Omit merges (--no-merges)
      -p  First parent only (--first-parent)
      l  Log HEAD
      b  Log dev
      a  Log all branches
      f  History of src/a b.ml
    Log
      -g  Show the graph (--graph)
      -m  Omit merges (--no-merges)
      -p  First parent only (--first-parent)
      l  Log HEAD
      b  Log a branch (select one in Branches first)
      a  Log all branches
      f  History of a file (select one first)
    (--graph --no-merges --first-parent)
    |}]
;;

let%expect_test "actions build choices from the enabled switches; scope reads them" =
  let popup = Log.popup ~branch:(Some "dev") ~file:(Some "f.ml") in
  let run key ~enabled =
    let state = Popup.initial popup ~enabled in
    match Popup.press popup state key with
    | Run choice ->
      print_s [%sexp (choice : Log.Choice.t)];
      (match Log.scope choice with
       | Error refusal -> printf "  refused: %s\n" refusal
       | Ok scope ->
         print_s [%sexp (scope : Log_scope.t)];
         (* The round trip: the popup reopens with what was chosen. *)
         printf
           "  round trip: %b\n"
           ([%equal: string list] (Log.enabled scope) choice.flags))
    | reply -> print_s [%sexp (reply : Log.Choice.t Popup.Reply.t)]
  in
  run 'l' ~enabled:(Log.enabled default);
  run 'b' ~enabled:[];
  run 'a' ~enabled:[ "--first-parent"; "--no-merges"; "--graph" ];
  run 'f' ~enabled:[ "--graph" ];
  [%expect
    {|
    ((target Head) (flags (--graph)))
    ((range Head) (path ()) (graph true) (merges true) (first_parent false)
     (limit 200))
      round trip: true
    ((target (Branch (dev))) (flags ()))
    ((range (Branch dev)) (path ()) (graph false) (merges true)
     (first_parent false) (limit 200))
      round trip: true
    ((target All) (flags (--graph --no-merges --first-parent)))
    ((range All) (path ()) (graph true) (merges false) (first_parent true)
     (limit 200))
      round trip: true
    ((target (File (f.ml))) (flags (--graph)))
    ((range Head) (path (f.ml)) (graph true) (merges true) (first_parent false)
     (limit 200))
      round trip: true
    |}];
  (* Refusals: no branch, no file. *)
  let popup = Log.popup ~branch:None ~file:None in
  List.iter [ 'b'; 'f' ] ~f:(fun key ->
    match Popup.press popup (Popup.initial popup) key with
    | Run choice ->
      print_s [%sexp (choice : Log.Choice.t)];
      (match Log.scope choice with
       | Error refusal -> printf "  refused: %s\n" refusal
       | Ok scope -> print_s [%sexp (scope : Log_scope.t)])
    | _ -> print_endline "not run");
  [%expect
    {|
    ((target (Branch ())) (flags ()))
      refused: Select a branch in Branches first
    ((target (File ())) (flags ()))
      refused: Select a file first: a Files item, or a file in the diff
    |}]
;;

let%expect_test "enabled: every combination, and scope inverts it" =
  List.iter [ true; false ] ~f:(fun graph ->
    List.iter [ true; false ] ~f:(fun merges ->
      List.iter [ false; true ] ~f:(fun first_parent ->
        let scope =
          { default with graph; merges; first_parent; range = All; limit = 400 }
        in
        let enabled = Log.enabled scope in
        let back = Log.scope { target = All; flags = enabled } |> Result.ok_or_failwith in
        printf
          "graph=%b merges=%b first_parent=%b: [%s] %s\n"
          graph
          merges
          first_parent
          (String.concat enabled ~sep:" ")
          (if Log_scope.equal back { scope with limit = Log_scope.default_limit }
           then "inverts"
           else Sexp.to_string [%sexp (back : Log_scope.t)]))));
  (* Flags the popup does not have are ignored. *)
  print_s
    [%sexp
      (Log.scope { target = Head; flags = [ "--stat"; "--no-merges" ] }
       : (Log_scope.t, string) Result.t)];
  [%expect
    {|
    graph=true merges=true first_parent=false: [--graph] inverts
    graph=true merges=true first_parent=true: [--graph --first-parent] inverts
    graph=true merges=false first_parent=false: [--graph --no-merges] inverts
    graph=true merges=false first_parent=true: [--graph --no-merges --first-parent] inverts
    graph=false merges=true first_parent=false: [] inverts
    graph=false merges=true first_parent=true: [--first-parent] inverts
    graph=false merges=false first_parent=false: [--no-merges] inverts
    graph=false merges=false first_parent=true: [--no-merges --first-parent] inverts
    (Ok
     ((range Head) (path ()) (graph false) (merges false) (first_parent false)
      (limit 200)))
    |}]
;;
