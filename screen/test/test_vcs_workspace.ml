(* The VCS workspace end to end: the default bindings ([Space g g/t/s/h/f]), the real
   VCS view installed as the frontend installs it, and git run synchronously by
   [Vcs_driver] in a fixture repository. Paths under the fixture print as $DIR;
   commit hashes are reproducible. *)

open! Core
open Ches_screen
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id
module Fixture = Ches_vcs_fixture.Fixture_repo

let width = 100
let height = 24

(* A repository with two committed files, one of them changed since. The editor opens
   [a.txt], with the default bindings. *)
let with_repo f =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "a.txt" "one\ntwo\nthree\nfour\n";
    Fixture.write repo "b.txt" "bee\n";
    ignore (Fixture.commit_all repo "first" : string);
    Fixture.write repo "a.txt" "one\nTWO\nthree\nfour\n";
    f repo)
;;

let create ?(entry = fun ~cwd -> Vcs_view.entry ~cwd ()) ~cwd path =
  let controller =
    Controller.open_file ~cell_width:Cell_map.width path |> Or_error.ok_exn
  in
  Ui_state.create ~tiles_visible:false ~views:[ entry ~cwd ] controller
;;

(* Keys, then every job the view submits, run to completion. *)
let run repo t keys =
  let t = Helpers.run ~width ~height t (Helpers.keys keys) in
  let t, jobs = Vcs_driver.settle repo t ~width ~height in
  if not (List.is_empty jobs)
  then printf "jobs: %s\n" (String.concat ~sep:", " (List.map jobs ~f:Vcs_driver.describe));
  t
;;

(* Fixture paths vary in length (they are under the build's temporary directory), and
   so does the padding after them: a row that names one is shown with runs of spaces
   squeezed. *)
let scrub (repo : Fixture.t) line =
  if String.is_substring line ~substring:repo.dir
  then
    String.substr_replace_all line ~pattern:repo.dir ~with_:"$DIR"
    |> String.split ~on:' '
    |> List.filter ~f:(Fn.non String.is_empty)
    |> String.concat ~sep:" "
  else line
;;

(* The code points of [line] from column [from] (frames here are single-width). *)
let from_column line from =
  let rec offset byte column =
    if byte >= String.length line || column = from
    then byte
    else (
      let next = ref (byte + 1) in
      while
        !next < String.length line && Char.to_int line.[!next] land 0xC0 = 0x80
      do
        incr next
      done;
      offset !next (column + 1))
  in
  String.drop_prefix line (offset 0 0)
;;

(* The frame, or with [from] only its columns from there on: the split view, without
   the editor pane, whose title is the fixture's path. *)
let show ?(from = 0) repo t =
  Frame.to_string (Frame.render t ~width ~height)
  |> String.split_lines
  |> List.iter ~f:(fun line ->
    print_endline
      (if String.is_prefix line ~prefix:"cursor:"
       then line
       else scrub repo (from_column line from)))
;;

let where t =
  let editor = Controller.editor (Ui_state.controller t) in
  printf
    "focused %s; vcs %s; active tab %s; file %s line %d\n"
    (View_id.to_string (Ui_state.focused_view t ~width ~height))
    (Sexp.to_string
       [%sexp
         (View_registry.placement (Ui_state.views t) Vcs_view.id
          : View_registry.Placement.t option)])
    (Option.value_map (Ui_state.active_tab_view t) ~default:"file" ~f:View_id.to_string)
    (Option.value_map (Ches_core.Editor.path editor) ~default:"none" ~f:Filename.basename)
    (Ches_core.Editor.cursor_line editor + 1)
;;

let vcs t = Option.value_exn (View_registry.find (Ui_state.views t) Vcs_view.key)

(* Where the split view starts at this size: the editor pane, then a gap. *)
let split_column = 51

let%expect_test "Space g g opens a tab with the repository; s, f and h move, focus, close" =
  with_repo (fun repo ->
    let t = create ~cwd:repo.work (Fixture.path repo "a.txt") in
    where t;
    [%expect {| focused document; vcs (Hidden); active tab file; file a.txt line 1 |}];
    let t = run repo t " gg" in
    where t;
    show repo t;
    [%expect {|
      jobs: detect g1.1, refresh g1.2, diff g1.3
      focused vcs; vcs (Tab); active tab vcs; file a.txt line 1
       1:a.txt [2:VCS]                                                                                    |
      ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
      │ Head: main 07a4bd0                    │ 0 Diff: Unstaged changes                                 │|
      │                                       │ diff --git a/a.txt b/a.txt                               │|
      │ 1 Files (1)                           │ index f384549..6addb9b 100644                            │|
      │ > - Unstaged changes (1)              │ --- a/a.txt                                              │|
      │   modified   a.txt                    │ +++ b/a.txt                                              │|
      │                                       │ @@ -1,4 +1,4 @@                                          │|
      │                                       │  one                                                     │|
      │                                       │ -two                                                     │|
      │                                       │ +TWO                                                     │|
      │                                       │  three                                                   │|
      │                                       │  four                                                    │|
      │                                       │                                                          │|
      │ 2 Branches (1)                        │                                                          │|
      │ > - Local branches (1)                │                                                          │|
      │   * main  first                       │                                                          │|
      │                                       │                                                          │|
      │ 3 Commits (1)                         │                                                          │|
      │ > - Recent commits (1)                │                                                          │|
      │   07a4bd0 first                       │                                                          │|
      │                                       │                                                          │|
      ╰─ Files 1/2 ──────────────────────────────────────────────────────────────────────────────────────╯|
       NORMAL  VCS VCS focused                                                                            |
      cursor: none
      |}];
    (* Moving it runs nothing: it was already shown. *)
    let t = run repo t " gs" in
    where t;
    show ~from:split_column repo t;
    [%expect {|
      focused vcs; vcs (Split); active tab file; file a.txt line 1
      ╭─ VCS: work (main) ────────────────────────────╮|
      │ Head: main 07a4bd0                            │|
      │ 1 Files (1)                                   │|
      │ > - Unstaged changes (1)                      │|
      │   modified   a.txt                            │|
      │                                               │|
      │                                               │|
      │                                               │|
      │ 2 Branches (1)                                │|
      │ > - Local branches (1)                        │|
      │ 3 Commits (1)                                 │|
      │ > - Recent commits (1)                        │|
      │ ───────────────────────────────────────────── │|
      │  0 Diff: Unstaged changes                     │|
      │  diff --git a/a.txt b/a.txt                   │|
      │  index f384549..6addb9b 100644                │|
      │  --- a/a.txt                                  │|
      │  +++ b/a.txt                                  │|
      │  @@ -1,4 +1,4 @@                              │|
      │   one                                         │|
      │  -two                                         │|
      │  +TWO                                         │|
      │   three                                       │|
      ╰─ VCS in split ────────────────────────────────╯|
      cursor: none
      |}];
    let t = run repo t " gf" in
    where t;
    let t = run repo t " gf" in
    where t;
    [%expect {|
      focused document; vcs (Split); active tab file; file a.txt line 1
      focused vcs; vcs (Split); active tab file; file a.txt line 1
      |}];
    let t = run repo t " gh" in
    where t;
    [%expect {| focused document; vcs (Hidden); active tab file; file a.txt line 1 |}];
    (* Reopened (straight into the split, then back to a tab), it reads again. *)
    let t = run repo t " gs" in
    where t;
    let t = run repo t " gt" in
    where t;
    [%expect {|
      jobs: detect g2.4, refresh g2.5, diff g2.6
      focused vcs; vcs (Split); active tab file; file a.txt line 1
      focused vcs; vcs (Tab); active tab vcs; file a.txt line 1
      |}])
;;

let%expect_test "saving a file in the repository refreshes the view once" =
  with_repo (fun repo ->
    let t = create ~cwd:repo.work (Fixture.path repo "a.txt") in
    let t = run repo t " gs gf" in
    where t;
    [%expect {|
      jobs: detect g1.1, refresh g1.2, diff g1.3
      focused document; vcs (Split); active tab file; file a.txt line 1
      |}];
    let t = run repo t "Ozero<Esc> w" in
    where t;
    show ~from:split_column repo t;
    [%expect {|
      jobs: refresh g1.4, diff g1.5
      focused document; vcs (Split); active tab file; file a.txt line 1
      ╭─ VCS: work (main) ────────────────────────────╮|
      │ Head: main 07a4bd0                            │|
      │ 1 Files (1)                                   │|
      │ > - Unstaged changes (1)                      │|
      │   modified   a.txt                            │|
      │                                               │|
      │                                               │|
      │                                               │|
      │ 2 Branches (1)                                │|
      │ > - Local branches (1)                        │|
      │ 3 Commits (1)                                 │|
      │ > - Recent commits (1)                        │|
      │ ───────────────────────────────────────────── │|
      │  0 Diff: Unstaged changes                     │|
      │  diff --git a/a.txt b/a.txt                   │|
      │  index f384549..e6cb1bc 100644                │|
      │  --- a/a.txt                                  │|
      │  +++ b/a.txt                                  │|
      │  @@ -1,4 +1,5 @@                              │|
      │  +zero                                        │|
      │   one                                         │|
      │  -two                                         │|
      │  +TWO                                         │|
      ╰─ Files 1/2 ───────────────────────────────────╯|
      cursor: 6,1 Block
      |}];
    (* A save outside the repository does not refresh it. *)
    let outside = Fixture.plain_dir repo "outside" in
    let t = create ~cwd:repo.work (outside ^/ "c.txt") in
    let t = run repo t " gs gf" in
    let t = run repo t "ic<Esc> w" in
    where t;
    [%expect {|
      jobs: detect g1.1, refresh g1.2, diff g1.3
      focused document; vcs (Split); active tab file; file c.txt line 1
      |}])
;;

let%expect_test "e in the diff opens the file at the line: from a tab, and beside the split" =
  with_repo (fun repo ->
    let t = create ~cwd:repo.work (Fixture.path repo "b.txt") in
    let t = run repo t " gg" in
    (* The Files panel starts on the section header; j selects a.txt, Enter focuses
       its diff, and the cursor goes to the +TWO line. *)
    let t = run repo t "j<CR>jjjjjjj" in
    let state = vcs t in
    print_s
      [%sexp
        { focus = (Vcs_view.focus state : Vcs_view.Focus.t)
        ; cursor = (Vcs_view.cursor state Files : Ches_vcs.Panel.Cursor.t)
        }];
    where t;
    [%expect {|
      jobs: detect g1.1, refresh g1.2, diff g1.3
      jobs: diff g1.4
      ((focus Diff)
       (cursor ((selected ((Item (section unstaged) (key a.txt)))) (folded ()))))
      focused vcs; vcs (Tab); active tab vcs; file b.txt line 1
      |}];
    let t = run repo t "e" in
    where t;
    [%expect {| focused document; vcs (Tab); active tab file; file a.txt line 2 |}];
    (* Beside the split, the file shows in the other pane, which gets focus. The diff
       keeps its cursor; the next line is " three". *)
    let t = run repo t " gs" in
    where t;
    let t = run repo t "je" in
    where t;
    [%expect {|
      focused vcs; vcs (Split); active tab file; file a.txt line 2
      focused document; vcs (Split); active tab file; file a.txt line 3
      |}])
;;

let%expect_test "outside any repository, the view says so" =
  with_repo (fun repo ->
    let elsewhere = Fixture.plain_dir repo "elsewhere" in
    let t = create ~cwd:elsewhere (Fixture.path repo "a.txt") in
    let t = run repo t " gg" in
    where t;
    show repo t;
    [%expect {|
      jobs: detect g1.1
      focused vcs; vcs (Tab); active tab vcs; file a.txt line 1
       1:a.txt [2:VCS]                                                                                    |
      ╭─ VCS: not a repository ──────────────────────────────────────────────────────────────────────────╮|
      │ Not a git repository:                                                                            │|
      │ $DIR/elsewhere │|
      │                                                                                                  │|
      │ g r looks again; q leaves                                                                        │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      │                                                                                                  │|
      ╰──────────────────────────────────────────────────────────────────────────────────────────────────╯|
       NORMAL  VCS VCS focused                                                                            |
      cursor: none
      |}])
;;

let%expect_test "without a runner the view is unavailable, and Space g says why" =
  with_repo (fun repo ->
    let entry ~cwd:_ =
      View_registry.Entry.unavailable
        Vcs_view.id
        ~title:"VCS"
        ~notice:"VCS unavailable in this session"
    in
    let t = create ~entry ~cwd:repo.work (Fixture.path repo "a.txt") in
    List.iter [ " gg"; " gs"; " gf"; " gt"; " gh" ] ~f:(fun keys ->
      let t = run repo t keys in
      printf
        "%-5S %s\n"
        keys
        (Option.value_map (Ui_state.message t) ~default:"(none)" ~f:(fun m -> m.text)));
    [%expect {|
      " gg" VCS unavailable in this session
      " gs" VCS unavailable in this session
      " gf" VCS unavailable in this session
      " gt" VCS unavailable in this session
      " gh" VCS unavailable in this session
      |}])
;;

(* {2 Phase 3: stage, unstage and discard with git's own plans} *)

(* Keys, quietly: the jobs they cause run to completion. *)
let act repo t keys =
  let t = Helpers.run ~width ~height t (Helpers.keys keys) in
  fst (Vcs_driver.settle repo t ~width ~height)
;;

(* The question, the footer notice, the feedback, the selection and git's status. *)
let outcome (repo : Fixture.t) t =
  let v = vcs t in
  Option.iter (Ui_state.confirm t) ~f:(fun confirm ->
    printf "confirm: %s: %s\n" (Confirm_tile.title confirm) (Confirm_tile.message confirm));
  Option.iter (Ui_state.capture_notice t) ~f:(printf "notice: %s\n");
  Option.iter (Ui_state.message t) ~f:(fun message ->
    if not (String.equal message.text "VCS focused") then printf "message: %s\n" message.text);
  printf "%s at %s\n"
    (Sexp.to_string [%sexp (Vcs_view.focus v : Vcs_view.Focus.t)])
    (Sexp.to_string
       [%sexp
         ((Vcs_view.cursor v (Vcs_view.list_focus v)).selected
          : Ches_vcs.Panel.Position.t option)]);
  printf "status: %s\n"
    (String.concat ~sep:", " (String.split_lines (Fixture.git repo [ "status"; "--short" ])))
;;

(* The log's mutations since [after] entries. *)
let mutations ?(after = 0) t =
  List.drop (Vcs_view.log (vcs t)) after
  |> List.iter ~f:(fun (entry : Vcs_view.Log_entry.t) ->
    let command =
      String.chop_prefix_if_exists entry.command
        ~prefix:(String.concat ~sep:" " ("git" :: Ches_vcs_git.Cli.prefix) ^ " ")
    in
    if List.exists [ "add"; "restore"; "apply"; "clean"; "reset"; "rm" ] ~f:(fun sub ->
         String.is_prefix command ~prefix:("--literal-pathspecs " ^ sub))
    then printf "log: [%s] git %s\n" (Option.value entry.status ~default:"running") command)
;;

let%expect_test "s and u stage and unstage a file; S and U everything" =
  with_repo (fun repo ->
    Fixture.write repo "new.txt" "new\n";
    let t = act repo (create ~cwd:repo.work (Fixture.path repo "a.txt")) " gg" in
    (* Rows: untracked header, new.txt, unstaged header, a.txt. *)
    let t = act repo t "jjjs" in
    outcome repo t;
    (* Rows now: untracked header, new.txt, staged header, a.txt. *)
    let t = act repo t "jjju" in
    outcome repo t;
    let t = act repo t "S" in
    outcome repo t;
    let t = act repo t "U" in
    outcome repo t;
    mutations t;
    [%expect {|
      Files at ((Header untracked))
      status: M  a.txt, ?? new.txt
      Files at ((Header untracked))
      status:  M a.txt, ?? new.txt
      Files at ((Header staged))
      status: M  a.txt, A  new.txt
      Files at ((Header untracked))
      status:  M a.txt, ?? new.txt
      log: [exit 0] git --literal-pathspecs add --all -- a.txt
      log: [exit 0] git --literal-pathspecs restore --staged -- a.txt
      log: [exit 0] git --literal-pathspecs add --all -- a.txt new.txt
      log: [exit 0] git --literal-pathspecs restore --staged -- a.txt new.txt
      |}])
;;

let%expect_test "a hunk of a two-hunk file is staged from the diff; one is discarded \
                 after y; an untracked file is deleted after y"
  =
  Fixture.with_repo (fun repo ->
    let lines = List.init 12 ~f:(fun i -> sprintf "line %d\n" (i + 1)) in
    Fixture.write repo "a.txt" (String.concat lines);
    ignore (Fixture.commit_all repo "first" : string);
    Fixture.write repo "a.txt"
      (String.concat
         (List.mapi lines ~f:(fun i line ->
            if i = 0 || i = 11 then String.uppercase line else line)));
    Fixture.write repo "junk.txt" "junk\n";
    let t = act repo (create ~cwd:repo.work (Fixture.path repo "a.txt")) " gg" in
    (* a.txt's diff: stage its first hunk. *)
    let t = act repo (act repo t "jjj<Tab>") "]s" in
    outcome repo t;
    print_string (Fixture.git repo [ "diff"; "--cached" ]);
    (* The cursor is on its other hunk: discard it, declining first. *)
    let t = act repo t "x" in
    outcome repo t;
    let t = act repo t "n" in
    let t = act repo t "xy" in
    outcome repo t;
    print_string (Fixture.git repo [ "diff" ]);
    (* The untracked file. *)
    let t = act repo (act repo t "<Tab>ggj") "x" in
    outcome repo t;
    let t = act repo t "y" in
    outcome repo t;
    printf "junk.txt exists: %b\n" (Sys_unix.file_exists_exn (Fixture.path repo "junk.txt"));
    mutations t;
    [%expect {|
      Diff at ((Item(section unstaged)(key a.txt)))
      status: MM a.txt, ?? junk.txt
      diff --git a/a.txt b/a.txt
      index 624b469..56727ea 100644
      --- a/a.txt
      +++ b/a.txt
      @@ -1,4 +1,4 @@
      -line 1
      +LINE 1
       line 2
       line 3
       line 4
      confirm: Discard hunk: Discard hunk 1/1 of a.txt? Its unstaged lines are lost.
      Diff at ((Item(section unstaged)(key a.txt)))
      status: MM a.txt, ?? junk.txt
      message: Reloaded from disk: a.txt
      Diff at ((Header staged))
      status: M  a.txt, ?? junk.txt
      confirm: Delete untracked file: Delete junk.txt? It is not in git and cannot be recovered.
      message: Reloaded from disk: a.txt
      Files at ((Item(section untracked)(key junk.txt)))
      status: M  a.txt, ?? junk.txt
      message: Reloaded from disk: a.txt
      Files at ((Header staged))
      status: M  a.txt
      junk.txt exists: false
      log: [exit 0] git --literal-pathspecs apply --cached --whitespace=nowarn --check
      log: [exit 0] git --literal-pathspecs apply --cached --whitespace=nowarn
      log: [exit 0] git --literal-pathspecs apply --reverse --whitespace=nowarn --check
      log: [exit 0] git --literal-pathspecs apply --reverse --whitespace=nowarn
      log: [exit 0] git --literal-pathspecs clean --force --quiet -- junk.txt
      |}])
;;

let%expect_test "a discard is refused while a buffer in the repository is dirty" =
  with_repo (fun repo ->
    let t = create ~cwd:repo.work (Fixture.path repo "a.txt") in
    let t = act repo t "Ax<Esc> gg" in
    let t = act repo t "jx" in
    outcome repo t;
    (* Staging warns instead. *)
    let t = act repo t "s" in
    outcome repo t;
    [%expect {|
      notice: Discard unstaged changes to a.txt refused: unsaved changes in a.txt; save or undo them first; nothing ran
      message: Discard unstaged changes to a.txt refused: unsaved changes in a.txt; save or undo them first; nothing ran
      Files at ((Item(section unstaged)(key a.txt)))
      status:  M a.txt
      notice: a.txt has unsaved changes: the saved files were staged, not the buffers
      message: a.txt has unsaved changes: the saved files were staged, not the buffers
      Files at ((Header staged))
      status: M  a.txt
      |}])
;;

let%expect_test "s on a conflicted file marks it resolved; u and x are refused" =
  Fixture.with_repo (fun repo ->
    let git args = ignore (Fixture.git repo args : string) in
    Fixture.write repo "a.txt" "base\n";
    ignore (Fixture.commit_all repo "base" : string);
    git [ "checkout"; "-q"; "-b"; "other" ];
    Fixture.write repo "a.txt" "other\n";
    ignore (Fixture.commit_all repo "other" : string);
    git [ "checkout"; "-q"; "main" ];
    Fixture.write repo "a.txt" "main\n";
    ignore (Fixture.commit_all repo "main" : string);
    (match Or_error.try_with (fun () -> git [ "merge"; "-q"; "other" ]) with
     | Ok () -> print_endline "merged?"
     | Error _ -> ());
    let t = act repo (create ~cwd:repo.work (Fixture.path repo "a.txt")) " gg" in
    let t = act repo t "ju" in
    outcome repo t;
    let t = act repo t "x" in
    outcome repo t;
    let t = act repo t "s" in
    outcome repo t;
    mutations t;
    [%expect {|
      notice: a.txt is conflicted: conflict resolution is not supported yet; resolve it in the editor, then stage it (s) to mark it resolved; nothing ran
      Files at ((Item(section conflicted)(key a.txt)))
      status: UU a.txt
      notice: a.txt is conflicted: conflict resolution is not supported yet; resolve it in the editor, then stage it (s) to mark it resolved; nothing ran
      Files at ((Item(section conflicted)(key a.txt)))
      status: UU a.txt
      Files at ((Header staged))
      status: M  a.txt
      log: [exit 0] git --literal-pathspecs add --all -- a.txt
      |}])
;;

(* {2 Phase 4: Visual s u x on selected lines, with git's own plans} *)

(* The diff panel's text, numbered, and the line the cursor is on. *)
let diff_text t =
  let view = Option.value_exn (Vcs_view.text_view (vcs t)) in
  let text = Ches_tile.Text_view.text view in
  let cursor =
    String.count (String.prefix text (Ches_tile.Text_view.cursor view)) ~f:(Char.equal '\n')
  in
  List.iteri (String.split_lines text) ~f:(fun i line ->
    printf "%s%2d|%s\n" (if i = cursor then "> " else "  ") i line)
;;

let%expect_test "V over two of three added lines, then s stages exactly those; u \
                 unstages a line of the staged diff"
  =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "a.txt" "one\ntwo\n";
    ignore (Fixture.commit_all repo "first" : string);
    Fixture.write repo "a.txt" "one\nA\nB\nC\ntwo\n";
    let t = act repo (create ~cwd:repo.work (Fixture.path repo "a.txt")) " gg" in
    let t = act repo (act repo t "j") "<Tab>6jVj" in
    let t = act repo t "s" in
    outcome repo t;
    print_string (Fixture.git repo [ "diff"; "--cached" ]);
    (* What is left unstaged; the cursor is on its hunk. *)
    diff_text t;
    [%expect {|
      Diff at ((Item(section unstaged)(key a.txt)))
      status: MM a.txt
      diff --git a/a.txt b/a.txt
      index 814f4a4..c4ac876 100644
      --- a/a.txt
      +++ b/a.txt
      @@ -1,2 +1,4 @@
       one
      +A
      +B
       two
         0|diff --git a/a.txt b/a.txt
         1|index c4ac876..ad24016 100644
         2|--- a/a.txt
         3|+++ b/a.txt
      >  4|@@ -1,4 +1,5 @@
         5| one
         6| A
         7| B
         8|+C
         9| two
      |}];
    (* The staged diff: unstage B. *)
    let t = act repo t "<Tab>G<Tab>" in
    diff_text t;
    let t = act repo t "7jVu" in
    outcome repo t;
    print_string (Fixture.git repo [ "diff"; "--cached" ]);
    mutations t;
    [%expect {|
      >  0|diff --git a/a.txt b/a.txt
         1|index 814f4a4..c4ac876 100644
         2|--- a/a.txt
         3|+++ b/a.txt
         4|@@ -1,2 +1,4 @@
         5| one
         6|+A
         7|+B
         8| two
      Diff at ((Item(section staged)(key a.txt)))
      status: MM a.txt
      diff --git a/a.txt b/a.txt
      index 814f4a4..d0ef1c7 100644
      --- a/a.txt
      +++ b/a.txt
      @@ -1,2 +1,3 @@
       one
      +A
       two
      log: [exit 0] git --literal-pathspecs apply --cached --whitespace=nowarn --check
      log: [exit 0] git --literal-pathspecs apply --cached --whitespace=nowarn
      log: [exit 0] git --literal-pathspecs apply --cached --reverse --whitespace=nowarn --check
      log: [exit 0] git --literal-pathspecs apply --cached --reverse --whitespace=nowarn
      |}])
;;

let%expect_test "x on lines across two hunks asks, and y discards them with one patch" =
  Fixture.with_repo (fun repo ->
    let lines = List.init 12 ~f:(fun i -> sprintf "line %d\n" (i + 1)) in
    Fixture.write repo "a.txt" (String.concat lines);
    ignore (Fixture.commit_all repo "first" : string);
    Fixture.write repo "a.txt"
      (String.concat
         (List.mapi lines ~f:(fun i line ->
            if i = 0 || i = 11 then String.uppercase line else line)));
    let t = act repo (create ~cwd:repo.work (Fixture.path repo "a.txt")) " gg" in
    (* From "-line 1" to "-line 12": three changes, not "+LINE 12". *)
    let t = act repo (act repo t "j") "<Tab>5jV9j" in
    let t = act repo t "x" in
    outcome repo t;
    let t = act repo t "y" in
    outcome repo t;
    print_string (Fixture.git repo [ "diff" ]);
    mutations t;
    [%expect {|
      confirm: Discard lines: Discard 3 lines of a.txt? Their unstaged changes are lost.
      Diff at ((Item(section unstaged)(key a.txt)))
      status:  M a.txt
      message: Reloaded from disk: a.txt
      Diff at ((Item(section unstaged)(key a.txt)))
      status:  M a.txt
      diff --git a/a.txt b/a.txt
      index 624b469..2072f2b 100644
      --- a/a.txt
      +++ b/a.txt
      @@ -10,3 +10,4 @@ line 9
       line 10
       line 11
       line 12
      +LINE 12
      log: [exit 0] git --literal-pathspecs apply --reverse --whitespace=nowarn --check
      log: [exit 0] git --literal-pathspecs apply --reverse --whitespace=nowarn
      |}])
;;

let%expect_test "lines of two files, and an untracked file's lines, are refused" =
  with_repo (fun repo ->
    Fixture.write repo "b.txt" "BEE\n";
    Fixture.write repo "new.txt" "new\n";
    let t = act repo (create ~cwd:repo.work (Fixture.path repo "a.txt")) " gg" in
    (* Rows: untracked header, new.txt, unstaged header (both files' diff). *)
    let t = act repo (act repo t "jj") "<Tab>VG" in
    let t = act repo t "s" in
    outcome repo t;
    let t = act repo (act repo t "<Tab>k") "<Tab>GV" in
    let t = act repo t "s" in
    outcome repo t;
    let t = act repo t "u" in
    outcome repo t;
    let t = act repo t "x" in
    outcome repo t;
    [%expect {|
      notice: Select lines within one file; nothing ran
      Diff at ((Header unstaged))
      status:  M a.txt,  M b.txt, ?? new.txt
      notice: Stage the whole untracked file first (s on its row); nothing ran
      Diff at ((Item(section untracked)(key new.txt)))
      status:  M a.txt,  M b.txt, ?? new.txt
      notice: new.txt is not staged; nothing ran
      Diff at ((Item(section untracked)(key new.txt)))
      status:  M a.txt,  M b.txt, ?? new.txt
      notice: Stage the whole untracked file first (s on its row); nothing ran
      Diff at ((Item(section untracked)(key new.txt)))
      status:  M a.txt,  M b.txt, ?? new.txt
      |}])
;;
