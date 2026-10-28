(* End-to-end tests of the git backend: its steps run synchronously against real
   repositories in isolated temp directories (Fixture_repo.run_steps), and the snapshot,
   panels, summary and diffs are checked. Paths under the fixture's temp directory print
   as $DIR; commit hashes are reproducible (fixed dates). *)

open! Core
open Ches_vcs
module Fixture = Ches_vcs_fixture.Fixture_repo
module Git = Ches_vcs_git
module B = Ches_vcs_git.Backend

let relative (t : Fixture.t) text =
  String.substr_replace_all text ~pattern:t.dir ~with_:"$DIR"
;;

let rec relative_sexp t : Sexp.t -> Sexp.t = function
  | Atom atom -> Atom (relative t atom)
  | List list -> List (List.map list ~f:(relative_sexp t))
;;

let git t args = ignore (Fixture.git t args : string)
let detect t ~cwd = B.detected ~cwd (Fixture.run_steps t (B.detect ~cwd))

let repository t =
  match detect t ~cwd:t.work with
  | Found repository -> repository
  | detection ->
    raise_s
      [%message
        "not a repository" (detection : Git.Repository.t Ches_vcs.Backend.Detection.t)]
;;

let snapshot_result ?(refresh = Ches_vcs.Backend.Refresh.default) t =
  let repository = repository t in
  B.snapshot repository refresh (Fixture.run_steps t (B.refresh repository refresh))
;;

let snapshot ?refresh t = ok_exn (snapshot_result ?refresh t)

let change (change : Git.Status.Change.t) =
  match change with
  | Unmodified -> "."
  | Modified -> "M"
  | Type_changed -> "T"
  | Added -> "A"
  | Deleted -> "D"
  | Renamed -> "R"
  | Copied -> "C"
  | Updated_unmerged -> "U"
;;

let submodule = function
  | None -> ""
  | Some { Git.Status.Submodule.commit_changed; tracked_changes; untracked_changes } ->
    sprintf
      " submodule%s%s%s"
      (if commit_changed then " new-commits" else "")
      (if tracked_changes then " modified" else "")
      (if untracked_changes then " untracked" else "")
;;

let describe_item : B.item -> string = function
  | File { entry; section = _ } ->
    (match entry with
     | Changed { index; worktree; submodule = sub; _ } ->
       change index ^ change worktree ^ submodule sub
     | Renamed_or_copied { index; worktree; score; original; submodule = sub; _ } ->
       sprintf
         "%s%s %d%% from %S%s"
         (change index)
         (change worktree)
         score
         original
         (submodule sub)
     | Unmerged { conflict; submodule = sub; _ } ->
       Git.Status.Conflict.to_string_hum conflict ^ submodule sub
     | Untracked _ -> "untracked"
     | Ignored _ -> "ignored")
  | Branch { name = _; oid; current; upstream; subject; committer_time = _ } ->
    sprintf
      "%s %s %S%s"
      (if current then "*" else " ")
      (String.prefix oid 7)
      subject
      (match upstream with
       | None -> ""
       | Some { name; tracking; _ } ->
         sprintf
           " -> %s %s"
           name
           (Sexp.to_string [%sexp (tracking : Git.Branch_list.Tracking.t)]))
  | Commit commit ->
    sprintf
      "%s parents=%d %S"
      (Git.Log.Commit.short_hash commit)
      (List.length commit.parents)
      commit.subject
;;

let print_panels (snapshot : B.snapshot) =
  List.iter (B.panels snapshot) ~f:(fun panel ->
    ok_exn (Panel.validate panel);
    printf "[%s] %s\n" (Panel.Id.to_string panel.id) panel.title;
    List.iter panel.sections ~f:(fun section ->
      printf "  %s (%s)\n" section.title (Panel.Section_id.to_string section.id);
      List.iter section.items ~f:(fun item ->
        printf "    %S %s\n" item.key (describe_item item.value))))
;;

let print_snapshot t (snapshot : B.snapshot) =
  print_s [%sexp (B.summary snapshot : Ches_vcs.Backend.Summary.t)];
  print_panels snapshot;
  List.iter snapshot.problems ~f:(fun problem ->
    printf "problem: %s\n" (relative t problem))
;;

let show_target ?(limits = Diff.Limits.default) t (snapshot : B.snapshot) target =
  print_s [%sexp (target : B.diff_target)];
  B.diff snapshot.repository target
  |> Fixture.run_steps t
  |> B.parse_diff target limits
  |> Show.or_error Show.diff
;;

let show_diff ?limits t snapshot panel position =
  match B.diff_target snapshot panel position with
  | None ->
    printf "no diff for %s\n" (Sexp.to_string [%sexp (position : Panel.Position.t)])
  | Some target -> show_target ?limits t snapshot target
;;

let header section = Panel.Position.Header (B.Section.id section)
let item section key = Panel.Position.Item { section = B.Section.id section; key }

let%expect_test "sections" =
  List.iter B.Section.all ~f:(fun section ->
    let id = B.Section.id section in
    printf
      "%s %S %b\n"
      (Panel.Section_id.to_string id)
      (B.Section.title section)
      ([%equal: B.Section.t option] (B.Section.of_id id) (Some section)));
  print_s
    [%sexp (B.Section.of_id (Panel.Section_id.of_string "local") : B.Section.t option)];
  print_s [%sexp (B.name : string)];
  [%expect
    {|
    conflicted "Conflicted" true
    untracked "Untracked files" true
    unstaged "Unstaged changes" true
    staged "Staged changes" true
    ignored "Ignored files" true
    ()
    git
    |}]
;;

let%expect_test "detection: work tree, subdirectory, plain directory, .git, bare" =
  Fixture.with_repo (fun t ->
    let show cwd =
      let detection = detect t ~cwd in
      print_s
        (relative_sexp
           t
           [%sexp (detection : Git.Repository.t Ches_vcs.Backend.Detection.t)])
    in
    Fixture.write t "src/deep/f.txt" "";
    git t [ "init"; "-q"; "--bare"; t.dir ^/ "bare.git" ];
    show t.work;
    show (Fixture.path t "src/deep");
    show (Fixture.plain_dir t "elsewhere");
    show (Fixture.path t ".git");
    show (Fixture.path t ".git/refs");
    show (t.dir ^/ "bare.git"));
  [%expect
    {|
    (Found ((root $DIR/work) (git_dir $DIR/work/.git)))
    (Found ((root $DIR/work) (git_dir $DIR/work/.git)))
    (Not_a_repository (cwd $DIR/elsewhere))
    (No_work_tree (cwd $DIR/work/.git)
     (message "fatal: this operation must be run in a work tree"))
    (No_work_tree (cwd $DIR/work/.git/refs)
     (message "fatal: this operation must be run in a work tree"))
    (No_work_tree (cwd $DIR/bare.git)
     (message "fatal: this operation must be run in a work tree"))
    |}]
;;

let%expect_test "an empty repository, then files staged before the first commit" =
  Fixture.with_repo (fun t ->
    let s = snapshot t in
    print_snapshot t s;
    show_diff t s B.files_panel (header Staged);
    Fixture.write t "new file.txt" "hello\r\nworld\r\n";
    Fixture.write t "empty" "";
    git t [ "add"; "." ];
    let s = snapshot t in
    print_snapshot t s;
    show_diff t s B.files_panel (header Staged));
  [%expect
    {|
    ((branch (main)) (revision ()) (upstream ()) (operations ()))
    [files] Files
    [branches] Branches
    [commits] Commits
    no diff for (Header staged)
    ((branch (main)) (revision ()) (upstream ()) (operations ()))
    [files] Files
      Staged changes (staged)
        "empty" A.
        "new file.txt" A.
    [branches] Branches
    [commits] Commits
    (Staged ())
    file - -> "empty" Added modes -..100644
    file - -> "new file.txt" Added modes -..100644
      @@ -0,0 +1,2 @@  [-0,0 +1,2] section=""
        add   .   1 "+"  "hello\r"
        add   .   2 "+"  "world\r"
    |}]
;;

let base_files t =
  Fixture.write t "a.txt" "one\ntwo\nthree\nfour\nfive\nsix\nseven\n";
  Fixture.write t "move me.txt" "alpha\nbeta\ngamma\ndelta\nepsilon\n";
  Fixture.write t "del.txt" "gone\n";
  Fixture.write t "mode.sh" "echo\n";
  Fixture.write t "bin.dat" "\000\001\002";
  Fixture.write t "nonl.txt" "last"
;;

let%expect_test "staged, unstaged, untracked, rename, deletion, mode, binary, odd names" =
  Fixture.with_repo (fun t ->
    base_files t;
    ignore (Fixture.commit_all t "First" : string);
    Fixture.write t "a.txt" "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\n";
    git t [ "add"; "a.txt" ];
    Fixture.write t "a.txt" "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight\n";
    git t [ "mv"; "move me.txt"; "moved \195\169.txt" ];
    git t [ "rm"; "-q"; "del.txt" ];
    git t [ "update-index"; "--chmod=+x"; "mode.sh" ];
    Fixture.write t "bin.dat" "\000\001\003";
    Fixture.write t "nonl.txt" "last\nmore";
    Fixture.write t "new\nline.txt" "x\n";
    Fixture.write t "q\"uote.txt" "x\n";
    Fixture.write t "dir/\195\188 file.txt" "x\n";
    let s = snapshot t in
    print_snapshot t s;
    print_endline "--- unstaged";
    show_diff t s B.files_panel (header Unstaged);
    print_endline "--- staged";
    show_diff t s B.files_panel (header Staged);
    print_endline "--- items";
    show_diff t s B.files_panel (item Staged "moved \195\169.txt");
    show_diff t s B.files_panel (item Staged "a.txt");
    show_diff t s B.files_panel (item Unstaged "a.txt");
    show_diff t s B.files_panel (item Untracked "new\nline.txt");
    show_diff t s B.files_panel (item Untracked "dir/\195\188 file.txt");
    show_diff t s B.files_panel (item Untracked "q\"uote.txt");
    show_diff t s B.files_panel (header Untracked);
    show_diff t s B.files_panel (item Untracked "absent");
    show_diff t s B.files_panel (item Conflicted "a.txt"));
  [%expect
    {|
    ((branch (main)) (revision (f6f211b)) (upstream ()) (operations ()))
    [files] Files
      Untracked files (untracked)
        "dir/\195\188 file.txt" untracked
        "new\nline.txt" untracked
        "q\"uote.txt" untracked
      Unstaged changes (unstaged)
        "a.txt" MM
        "bin.dat" .M
        "mode.sh" MM
        "nonl.txt" .M
      Staged changes (staged)
        "a.txt" MM
        "del.txt" D.
        "mode.sh" MM
        "moved \195\169.txt" R. 100% from "move me.txt"
    [branches] Branches
      Local branches (local)
        "main" * f6f211b "First"
    [commits] Commits
      Recent commits (recent)
        "f6f211b39c22b5c8f9d4e43f9c3f1e2fe1181c49" f6f211b parents=0 "First"
    --- unstaged
    (Unstaged ())
    file "a.txt" -> "a.txt" Modified modes 100644..100644
      @@ -5,3 +5,4 @@ four  [-5,3 +5,4] section="four"
        ctx   5   5 " "  "five"
        ctx   6   6 " "  "six"
        ctx   7   7 " "  "seven"
        add   .   8 "+"  "eight"
    file "bin.dat" -> "bin.dat" Modified modes 100644..100644 binary no-line-actions
    file "mode.sh" -> "mode.sh" Modified modes 100755..100644 mode-only no-line-actions
    file "nonl.txt" -> "nonl.txt" Modified modes 100644..100644
      @@ -1 +1,2 @@  [-1,1 +1,2] section=""
        del   1   . "-"  "last"
        eof   .   . "\\" " No newline at end of file"
        add   .   1 "+"  "last"
        add   .   2 "+"  "more"
        eof   .   . "\\" " No newline at end of file"
    --- staged
    (Staged ())
    file "a.txt" -> "a.txt" Modified modes 100644..100644
      @@ -1,6 +1,6 @@  [-1,6 +1,6] section=""
        ctx   1   1 " "  "one"
        ctx   2   2 " "  "two"
        del   3   . "-"  "three"
        add   .   3 "+"  "THREE"
        ctx   4   4 " "  "four"
        ctx   5   5 " "  "five"
        ctx   6   6 " "  "six"
    file "del.txt" -> - Deleted modes 100644..-
      @@ -1 +0,0 @@  [-1,1 +0,0] section=""
        del   1   . "-"  "gone"
    file "mode.sh" -> "mode.sh" Modified modes 100644..100755 mode-only no-line-actions
    file "move me.txt" -> "moved \195\169.txt" (Renamed(similarity(100))) modes -..- rename-only no-line-actions
    --- items
    (Staged ("move me.txt" "moved \195\169.txt"))
    file "move me.txt" -> "moved \195\169.txt" (Renamed(similarity(100))) modes -..- rename-only no-line-actions
    (Staged (a.txt))
    file "a.txt" -> "a.txt" Modified modes 100644..100644
      @@ -1,6 +1,6 @@  [-1,6 +1,6] section=""
        ctx   1   1 " "  "one"
        ctx   2   2 " "  "two"
        del   3   . "-"  "three"
        add   .   3 "+"  "THREE"
        ctx   4   4 " "  "four"
        ctx   5   5 " "  "five"
        ctx   6   6 " "  "six"
    (Unstaged (a.txt))
    file "a.txt" -> "a.txt" Modified modes 100644..100644
      @@ -5,3 +5,4 @@ four  [-5,3 +5,4] section="four"
        ctx   5   5 " "  "five"
        ctx   6   6 " "  "six"
        ctx   7   7 " "  "seven"
        add   .   8 "+"  "eight"
    (Untracked  "new\
               \nline.txt")
    file - -> "new\nline.txt" Added modes -..100644
      @@ -0,0 +1 @@  [-0,0 +1,1] section=""
        add   .   1 "+"  "x"
    (Untracked "dir/\195\188 file.txt")
    file - -> "dir/\195\188 file.txt" Added modes -..100644
      @@ -0,0 +1 @@  [-0,0 +1,1] section=""
        add   .   1 "+"  "x"
    (Untracked "q\"uote.txt")
    file - -> "q\"uote.txt" Added modes -..100644
      @@ -0,0 +1 @@  [-0,0 +1,1] section=""
        add   .   1 "+"  "x"
    no diff for (Header untracked)
    no diff for (Item(section untracked)(key absent))
    no diff for (Item(section conflicted)(key a.txt))
    |}]
;;

(* Seven conflicts, one per unmerged XY code, from one real merge. *)
let conflicting_branches t =
  Fixture.write t "uu.txt" "base\n";
  Fixture.write t "ud.txt" "base\n";
  Fixture.write t "du.txt" "base\n";
  Fixture.write t "dd.txt" "base\n";
  ignore (Fixture.commit_all t "base" : string);
  git t [ "checkout"; "-q"; "-b"; "other" ];
  Fixture.write t "uu.txt" "theirs\n";
  git t [ "rm"; "-q"; "ud.txt" ];
  Fixture.write t "du.txt" "theirs\n";
  git t [ "mv"; "dd.txt"; "dd-other.txt" ];
  Fixture.write t "aa.txt" "theirs\n";
  ignore (Fixture.commit_all t "other" : string);
  git t [ "checkout"; "-q"; "main" ];
  Fixture.write t "uu.txt" "ours\n";
  Fixture.write t "ud.txt" "ours\n";
  git t [ "rm"; "-q"; "du.txt" ];
  git t [ "mv"; "dd.txt"; "dd-main.txt" ];
  Fixture.write t "aa.txt" "ours\n";
  ignore (Fixture.commit_all t "main" : string)
;;

(* Run git expecting it to fail (a conflict). *)
let git_fails t args =
  let result = Fixture.run t (Exec.Spec.create ~kind:Mutate ~cwd:t.work "git" args) in
  printf "git %s: %s\n" (String.concat ~sep:" " args) (Exec.Result.status_hum result)
;;

let%expect_test "a conflict from a real merge: every unmerged code" =
  Fixture.with_repo (fun t ->
    conflicting_branches t;
    git_fails t [ "merge"; "-q"; "other" ];
    let s = snapshot t in
    print_snapshot t s;
    show_diff t s B.files_panel (header Conflicted);
    show_diff t s B.files_panel (item Conflicted "du.txt"));
  [%expect
    {|
    git merge -q other: exit 1
    ((branch (main)) (revision (90c5cb5)) (upstream ())
     (operations ("Merging 4e98047")))
    [files] Files
      Conflicted (conflicted)
        "aa.txt" both added
        "dd-main.txt" added by us
        "dd-other.txt" added by them
        "dd.txt" both deleted
        "du.txt" deleted by us
        "ud.txt" deleted by them
        "uu.txt" both modified
    [branches] Branches
      Local branches (local)
        "main" * 90c5cb5 "main"
        "other"   4e98047 "other"
    [commits] Commits
      Recent commits (recent)
        "90c5cb54338b3e966f85a53c2456c64507430730" 90c5cb5 parents=1 "main"
        "094c72757d883448bacd136df74f59311df7f7da" 094c727 parents=0 "base"
    (Conflicted (aa.txt dd-main.txt dd-other.txt dd.txt du.txt ud.txt uu.txt))
    file "aa.txt" -> "aa.txt" Unmerged modes -..- combined no-line-actions
      @@@ -1,1 -1,1 +1,5 @@@  [-1,1 +1,5] section=""
        add   .   1 "++" "<<<<<<< HEAD"
        add   .   2 " +" "ours"
        add   .   3 "++" "======="
        add   .   4 "+ " "theirs"
        add   .   5 "++" ">>>>>>> other"
    file "uu.txt" -> "uu.txt" Unmerged modes -..- combined no-line-actions
      @@@ -1,1 -1,1 +1,5 @@@  [-1,1 +1,5] section=""
        add   .   1 "++" "<<<<<<< HEAD"
        add   .   2 " +" "ours"
        add   .   3 "++" "======="
        add   .   4 "+ " "theirs"
        add   .   5 "++" ">>>>>>> other"
    file "dd-main.txt" -> "dd-main.txt" Unmerged modes -..- no-line-actions
    file "dd-other.txt" -> "dd-other.txt" Unmerged modes -..- no-line-actions
    file "dd.txt" -> "dd.txt" Unmerged modes -..- no-line-actions
    file "du.txt" -> "du.txt" Unmerged modes -..- no-line-actions
    file "ud.txt" -> "ud.txt" Unmerged modes -..- no-line-actions
    (Conflicted (du.txt))
    file "du.txt" -> "du.txt" Unmerged modes -..- no-line-actions
    |}]
;;

let%expect_test "rebase, cherry-pick, revert and bisect in progress" =
  Fixture.with_repo (fun t ->
    conflicting_branches t;
    let operations () =
      let s = snapshot t in
      let summary = B.summary s in
      print_s
        [%sexp
          (summary.branch : string option)
          , (summary.operations : string list)
          , (s.problems : string list)]
    in
    git_fails t [ "rebase"; "other" ];
    operations ();
    git t [ "rebase"; "--abort" ];
    git_fails t [ "cherry-pick"; "other" ];
    operations ();
    git t [ "cherry-pick"; "--abort" ];
    Fixture.write t "uu.txt" "v2\n";
    ignore (Fixture.commit_all t "v2" : string);
    Fixture.write t "uu.txt" "v3\n";
    ignore (Fixture.commit_all t "v3" : string);
    git_fails t [ "revert"; "--no-edit"; "HEAD~1" ];
    operations ();
    git t [ "revert"; "--abort" ];
    git t [ "bisect"; "start" ];
    operations ();
    git t [ "bisect"; "reset" ];
    operations ());
  [%expect
    {|
    git rebase other: exit 1
    (() ("Rebasing main onto 4e98047") ())
    git cherry-pick other: exit 1
    ((main) ("Cherry-picking 4e98047") ())
    git revert --no-edit HEAD~1: exit 1
    ((main) ("Reverting a846420") ())
    ((main) (Bisecting) ())
    ((main) () ())
    |}]
;;

let%expect_test "upstreams: ahead, behind, in sync, gone; detached HEAD" =
  Fixture.with_repo ~remote:true (fun t ->
    Fixture.write t "f.txt" "1\n";
    ignore (Fixture.commit_all t "One" : string);
    git t [ "push"; "-q"; "-u"; "origin"; "main" ];
    Fixture.write t "f.txt" "2\n";
    ignore (Fixture.commit_all t "Two" : string);
    git t [ "push"; "-q" ];
    git t [ "reset"; "-q"; "--hard"; "HEAD~1" ];
    Fixture.write t "g.txt" "3\n";
    ignore (Fixture.commit_all t "Three" : string);
    git t [ "branch"; "--track"; "in-sync"; "origin/main" ];
    git t [ "push"; "-q"; "origin"; "main:doomed" ];
    git t [ "branch"; "--track"; "doomed"; "origin/doomed" ];
    git t [ "push"; "-q"; "origin"; ":doomed" ];
    git t [ "fetch"; "-q"; "--prune" ];
    git t [ "branch"; "plain" ];
    print_snapshot t (snapshot t);
    git t [ "checkout"; "-q"; "doomed" ];
    print_s [%sexp (B.summary (snapshot t) : Ches_vcs.Backend.Summary.t)];
    git t [ "checkout"; "-q"; "--detach"; "HEAD~1" ];
    print_s [%sexp (B.summary (snapshot t) : Ches_vcs.Backend.Summary.t)]);
  [%expect
    {|
    ((branch (main)) (revision (5cd767d))
     (upstream (((name origin/main) (ahead 1) (behind 1) (gone false))))
     (operations ()))
    [files] Files
    [branches] Branches
      Local branches (local)
        "doomed"   5cd767d "Three" -> origin/doomed Gone
        "in-sync"   46b9e32 "Two" -> origin/main In_sync
        "main" * 5cd767d "Three" -> origin/main (Ahead_behind(ahead 1)(behind 1))
        "plain"   5cd767d "Three"
    [commits] Commits
      Recent commits (recent)
        "5cd767dd2e9b4cbb8e00b8fcc92a7d50c51b6ae8" 5cd767d parents=1 "Three"
        "ed338fbda3f2ebeb2c7472be36e6d6b45ade8f6d" ed338fb parents=0 "One"
    ((branch (doomed)) (revision (5cd767d))
     (upstream (((name origin/doomed) (ahead 0) (behind 0) (gone true))))
     (operations ()))
    ((branch ()) (revision (ed338fb)) (upstream ()) (operations ()))
    |}]
;;

let%expect_test "commits: a commit's diff, a merge, the log limit, other rows" =
  Fixture.with_repo (fun t ->
    conflicting_branches t;
    git t [ "merge"; "-q"; "--no-ff"; "-s"; "ours"; "-m"; "Merge other"; "other" ];
    let s = snapshot ~refresh:{ ignored = false; log_limit = 3 } t in
    print_panels s;
    List.iter s.commits ~f:(fun commit ->
      show_diff
        t
        s
        B.commits_panel
        (Item { section = Panel.Section_id.of_string "recent"; key = commit.hash }));
    show_diff t s B.commits_panel (Header (Panel.Section_id.of_string "recent"));
    show_diff
      t
      s
      B.branches_panel
      (Item { section = Panel.Section_id.of_string "local"; key = "main" });
    show_diff t s (Panel.Id.of_string "elsewhere") (header Staged));
  [%expect
    {|
    [files] Files
    [branches] Branches
      Local branches (local)
        "main" * cdd6501 "Merge other"
        "other"   4e98047 "other"
    [commits] Commits
      Recent commits (recent)
        "cdd6501016da4a4c930931c0a6ce4379639d0aab" cdd6501 parents=2 "Merge other"
        "90c5cb54338b3e966f85a53c2456c64507430730" 90c5cb5 parents=1 "main"
        "4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94" 4e98047 parents=1 "other"
    (Commit cdd6501016da4a4c930931c0a6ce4379639d0aab)
    preamble |commit cdd6501016da4a4c930931c0a6ce4379639d0aab
    preamble |Merge: 90c5cb5 4e98047
    preamble |Author:     Ches Test <ches-test@example.invalid>
    preamble |AuthorDate: 2026-01-01T00:00:00+00:00
    preamble |Commit:     Ches Test <ches-test@example.invalid>
    preamble |CommitDate: 2026-01-01T00:00:00+00:00
    preamble |
    preamble |    Merge other
    preamble |
    (Commit 90c5cb54338b3e966f85a53c2456c64507430730)
    preamble |commit 90c5cb54338b3e966f85a53c2456c64507430730
    preamble |Author:     Ches Test <ches-test@example.invalid>
    preamble |AuthorDate: 2026-01-01T00:00:00+00:00
    preamble |Commit:     Ches Test <ches-test@example.invalid>
    preamble |CommitDate: 2026-01-01T00:00:00+00:00
    preamble |
    preamble |    main
    preamble |
    file - -> "aa.txt" Added modes -..100644
      @@ -0,0 +1 @@  [-0,0 +1,1] section=""
        add   .   1 "+"  "ours"
    file "dd.txt" -> "dd-main.txt" (Renamed(similarity(100))) modes -..- rename-only no-line-actions
    file "du.txt" -> - Deleted modes 100644..-
      @@ -1 +0,0 @@  [-1,1 +0,0] section=""
        del   1   . "-"  "base"
    file "ud.txt" -> "ud.txt" Modified modes 100644..100644
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "base"
        add   .   1 "+"  "ours"
    file "uu.txt" -> "uu.txt" Modified modes 100644..100644
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "base"
        add   .   1 "+"  "ours"
    (Commit 4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94)
    preamble |commit 4e98047b76b41ae3032a4e0b5efbacaa2ea6cc94
    preamble |Author:     Ches Test <ches-test@example.invalid>
    preamble |AuthorDate: 2026-01-01T00:00:00+00:00
    preamble |Commit:     Ches Test <ches-test@example.invalid>
    preamble |CommitDate: 2026-01-01T00:00:00+00:00
    preamble |
    preamble |    other
    preamble |
    file - -> "aa.txt" Added modes -..100644
      @@ -0,0 +1 @@  [-0,0 +1,1] section=""
        add   .   1 "+"  "theirs"
    file "dd.txt" -> "dd-other.txt" (Renamed(similarity(100))) modes -..- rename-only no-line-actions
    file "du.txt" -> "du.txt" Modified modes 100644..100644
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "base"
        add   .   1 "+"  "theirs"
    file "ud.txt" -> - Deleted modes 100644..-
      @@ -1 +0,0 @@  [-1,1 +0,0] section=""
        del   1   . "-"  "base"
    file "uu.txt" -> "uu.txt" Modified modes 100644..100644
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "base"
        add   .   1 "+"  "theirs"
    no diff for (Header recent)
    no diff for (Item(section local)(key main))
    no diff for (Header staged)
    |}]
;;

let%expect_test "a submodule: added, then with new commits and untracked files" =
  Fixture.with_repo (fun t ->
    Fixture.write t "top.txt" "top\n";
    ignore (Fixture.commit_all t "Top" : string);
    let sub = Fixture.path t "sub" in
    git t [ "init"; "-q"; "sub" ];
    Fixture.write t "sub/s.txt" "s\n";
    ignore (Fixture.git ~cwd:sub t [ "add"; "." ] : string);
    ignore (Fixture.git ~cwd:sub t [ "commit"; "-q"; "-m"; "s" ] : string);
    git t [ "add"; "sub" ];
    let s = snapshot t in
    print_panels s;
    show_diff t s B.files_panel (item Staged "sub");
    git t [ "commit"; "-q"; "-m"; "Add sub" ];
    Fixture.write t "sub/s.txt" "s2\n";
    ignore (Fixture.git ~cwd:sub t [ "commit"; "-q"; "-am"; "s2" ] : string);
    Fixture.write t "sub/u.txt" "u\n";
    let s = snapshot t in
    print_panels s;
    show_diff t s B.files_panel (item Unstaged "sub"));
  [%expect
    {|
    [files] Files
      Staged changes (staged)
        "sub" A. submodule
    [branches] Branches
      Local branches (local)
        "main" * f703627 "Top"
    [commits] Commits
      Recent commits (recent)
        "f703627be85d6e02d53b35f4116246fad8530624" f703627 parents=0 "Top"
    (Staged (sub))
    file - -> "sub" Added modes -..160000 submodule no-line-actions
      @@ -0,0 +1 @@  [-0,0 +1,1] section=""
        add   .   1 "+"  "Subproject commit b308c3e56c484d4daeb357bae251e8e8ac99b4ed"
    [files] Files
      Unstaged changes (unstaged)
        "sub" .M submodule new-commits untracked
    [branches] Branches
      Local branches (local)
        "main" * 01dff01 "Add sub"
    [commits] Commits
      Recent commits (recent)
        "01dff01ecb6a41babce565aea1317c44087991f4" 01dff01 parents=1 "Add sub"
        "f703627be85d6e02d53b35f4116246fad8530624" f703627 parents=0 "Top"
    (Unstaged (sub))
    file "sub" -> "sub" Modified modes 160000..160000 submodule no-line-actions
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "Subproject commit b308c3e56c484d4daeb357bae251e8e8ac99b4ed"
        add   .   1 "+"  "Subproject commit 5928c94995a4d27bbdb81295224ad8258d35804c"
    |}]
;;

let%expect_test "ignored files only on request" =
  Fixture.with_repo (fun t ->
    Fixture.write t ".gitignore" "build/\n*.o\n";
    ignore (Fixture.commit_all t "Ignore" : string);
    Fixture.write t "build/out.o" "";
    Fixture.write t "top.o" "";
    Fixture.write t "kept.txt" "";
    print_panels (snapshot t);
    let s = snapshot ~refresh:{ ignored = true; log_limit = 1 } t in
    print_panels s;
    show_diff t s B.files_panel (header Ignored);
    show_diff t s B.files_panel (item Ignored "top.o"));
  [%expect
    {|
    [files] Files
      Untracked files (untracked)
        "kept.txt" untracked
    [branches] Branches
      Local branches (local)
        "main" * dba157f "Ignore"
    [commits] Commits
      Recent commits (recent)
        "dba157f3cfa1d0326f78644bfe9f3e081718bd0a" dba157f parents=0 "Ignore"
    [files] Files
      Untracked files (untracked)
        "kept.txt" untracked
      Ignored files (ignored)
        "build/" ignored
        "top.o" ignored
    [branches] Branches
      Local branches (local)
        "main" * dba157f "Ignore"
    [commits] Commits
      Recent commits (recent)
        "dba157f3cfa1d0326f78644bfe9f3e081718bd0a" dba157f parents=0 "Ignore"
    no diff for (Header ignored)
    no diff for (Item(section ignored)(key top.o))
    |}]
;;

let%expect_test "an untracked nested repository is a directory key without a diff" =
  Fixture.with_repo (fun t ->
    Fixture.write t "top.txt" "top\n";
    ignore (Fixture.commit_all t "Top" : string);
    Fixture.write t "nested/inner.txt" "inner\n";
    ignore (Fixture.git t [ "init"; "-q"; "nested" ] : string);
    Fixture.write t "loose.txt" "loose\n";
    let s = snapshot t in
    print_panels s;
    show_diff t s B.files_panel (item Untracked "nested/");
    show_diff t s B.files_panel (item Untracked "loose.txt"));
  [%expect {|
    [files] Files
      Untracked files (untracked)
        "loose.txt" untracked
        "nested/" untracked
    [branches] Branches
      Local branches (local)
        "main" * f703627 "Top"
    [commits] Commits
      Recent commits (recent)
        "f703627be85d6e02d53b35f4116246fad8530624" f703627 parents=0 "Top"
    no diff for (Item(section untracked)(key nested/))
    (Untracked loose.txt)
    file - -> "loose.txt" Added modes -..100644
      @@ -0,0 +1 @@  [-0,0 +1,1] section=""
        add   .   1 "+"  "loose"
    |}]
;;

let%expect_test "a huge file: per-file limits, and output cut at its limit" =
  Fixture.with_repo (fun t ->
    let lines n prefix =
      String.concat (List.init n ~f:(fun i -> sprintf "%s %d\n" prefix i))
    in
    Fixture.write t "huge.txt" (lines 5000 "line");
    Fixture.write t "small.txt" "small\n";
    ignore (Fixture.commit_all t "Huge" : string);
    (* Every 10th line changes: many hunks. *)
    Fixture.write
      t
      "huge.txt"
      (String.concat
         (List.init 5000 ~f:(fun i ->
            if i % 10 = 5 then sprintf "changed %d\n" i else sprintf "line %d\n" i)));
    Fixture.write t "small.txt" "SMALL\n";
    let s = snapshot t in
    let limits = { Diff.Limits.file_lines = 30; file_bytes = 1_000_000 } in
    show_target ~limits t s (Unstaged []);
    (* The same command with a tiny stdout limit: the runner keeps a prefix. *)
    let target = B.Unstaged [ "huge.txt" ] in
    let steps =
      List.map (B.diff s.repository target) ~f:(function
        | Run spec -> Job.Step.Run { spec with stdout_limit = 400 }
        | step -> step)
    in
    Fixture.run_steps t steps |> B.parse_diff target limits |> Show.or_error Show.diff);
  [%expect
    {|
    (Unstaged ())
    file "huge.txt" -> "huge.txt" Modified modes 100644..100644
      truncated ((omitted_hunks 497) (omitted_lines 3976) (cut false))
      @@ -3,7 +3,7 @@ line 1  [-3,7 +3,7] section="line 1"
        ctx   3   3 " "  "line 2"
        ctx   4   4 " "  "line 3"
        ctx   5   5 " "  "line 4"
        del   6   . "-"  "line 5"
        add   .   6 "+"  "changed 5"
        ctx   7   7 " "  "line 6"
        ctx   8   8 " "  "line 7"
        ctx   9   9 " "  "line 8"
      @@ -13,7 +13,7 @@ line 11  [-13,7 +13,7] section="line 11"
        ctx  13  13 " "  "line 12"
        ctx  14  14 " "  "line 13"
        ctx  15  15 " "  "line 14"
        del  16   . "-"  "line 15"
        add   .  16 "+"  "changed 15"
        ctx  17  17 " "  "line 16"
        ctx  18  18 " "  "line 17"
        ctx  19  19 " "  "line 18"
      @@ -23,7 +23,7 @@ line 21  [-23,7 +23,7] section="line 21"
        ctx  23  23 " "  "line 22"
        ctx  24  24 " "  "line 23"
        ctx  25  25 " "  "line 24"
        del  26   . "-"  "line 25"
        add   .  26 "+"  "changed 25"
        ctx  27  27 " "  "line 26"
        ctx  28  28 " "  "line 27"
        ctx  29  29 " "  "line 28"
    file "small.txt" -> "small.txt" Modified modes 100644..100644
      @@ -1 +1 @@  [-1,1 +1,1] section=""
        del   1   . "-"  "small"
        add   .   1 "+"  "SMALL"
    file "huge.txt" -> "huge.txt" Modified modes 100644..100644
      truncated ((omitted_hunks 0) (omitted_lines 0) (cut true))
      @@ -3,7 +3,7 @@ line 1  [-3,7 +3,7] section="line 1"
        ctx   3   3 " "  "line 2"
        ctx   4   4 " "  "line 3"
        ctx   5   5 " "  "line 4"
        del   6   . "-"  "line 5"
        add   .   6 "+"  "changed 5"
        ctx   7   7 " "  "line 6"
        ctx   8   8 " "  "line 7"
        ctx   9   9 " "  "line 8"
      @@ -13,7 +13,7 @@ line 11  [-13,7 +13,7] section="line 11"
        ctx  13  13 " "  "line 12"
        ctx  14  14 " "  "line 13"
        ctx  15  15 " "  "line 14"
        del  16   . "-"  "line 15"
        add   .  16 "+"  "changed 15"
        ctx  17  17 " "  "line 16"
        ctx  18  18 " "  "line 17"
        ctx  19  19 " "  "line 18"
      @@ -23,7 +23,7 @@ line 21  [-23,7 +23,7] section="line 21"
        ctx  23  23 " "  "line 22"
        ctx  24  24 " "  "line 23"
        ctx  25  25 " "  "line 24"
        del  26   . "-"  "line 25"
        add   .  26 "+"  "changed 25"
        ctx  27  27 " "  "line 26"
        ctx  28  28 " "  "line 27"
        ctx  29  29 " "  "line 28"
    (output cut)
    |}]
;;

let%expect_test "failed steps: status is fatal, the rest degrade the snapshot" =
  Fixture.with_repo (fun t ->
    Fixture.write t "f.txt" "f\n";
    ignore (Fixture.commit_all t "F" : string);
    let repository = repository t in
    let refresh = Ches_vcs.Backend.Refresh.default in
    let reports = Fixture.run_steps t (B.refresh repository refresh) in
    let failed (report : Job.Step_report.t) =
      { report with
        outcome = Ran (Show.result ~status:(Exited 128) ~stderr:"fatal: broken\n" "")
      }
    in
    let replace index f =
      List.mapi reports ~f:(fun i r -> if i = index then f r else r)
    in
    let show reports =
      match B.snapshot repository refresh reports with
      | Error error -> print_endline (relative t (Error.to_string_hum error))
      | Ok s ->
        printf
          "ok: %d branches, %d commits, %d operations\n"
          (List.length s.branches)
          (List.length s.commits)
          (List.length s.operations);
        List.iter s.problems ~f:(fun problem ->
          printf "problem: %s\n" (relative t problem))
    in
    show reports;
    show (replace 0 failed);
    show (replace 1 failed);
    show (replace 2 failed);
    show
      (replace 5 (fun report ->
         { report with outcome = Read (Failed "Permission denied") }));
    show (replace 4 (fun report -> { report with outcome = Skipped }));
    show (List.tl_exn reports);
    show (replace 1 (fun report -> { report with outcome = Ran (Show.result "garbage") })));
  [%expect
    {|
    ok: 1 branches, 1 commits, 0 operations
    git --no-pager -c color.ui=false -c core.quotepath=false status --porcelain=v2 -z --branch --untracked-files=all --find-renames: exit 128: fatal: broken
    ok: 0 branches, 1 commits, 0 operations
    problem: git --no-pager -c color.ui=false -c core.quotepath=false for-each-ref '--format=%(refname:short)%00%(objectname)%00%(HEAD)%00%(upstream)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(contents:subject)%00%(upstream:remotename)%00%(upstream:remoteref)%00' refs/heads: exit 128: fatal: broken
    ok: 1 branches, 0 commits, 0 operations
    problem: git --no-pager -c color.ui=false -c core.quotepath=false log -z --no-color --no-show-signature --max-count=200 --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s HEAD --: exit 128: fatal: broken
    ok: 1 branches, 1 commits, 0 operations
    problem: $DIR/work/.git/rebase-apply/head-name: Permission denied
    $DIR/work/.git/rebase-merge/onto: skipped
    ("git refresh: the report does not match the refresh's steps" (steps 11)
     (expected 12))
    ok: 0 branches, 1 commits, 0 operations
    problem: git --no-pager -c color.ui=false -c core.quotepath=false for-each-ref '--format=%(refname:short)%00%(objectname)%00%(HEAD)%00%(upstream)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(contents:subject)%00%(upstream:remotename)%00%(upstream:remoteref)%00' refs/heads: ("unterminated branch line"(tail garbage))
    |}]
;;
