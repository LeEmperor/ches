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
