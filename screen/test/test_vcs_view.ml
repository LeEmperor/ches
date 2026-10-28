(* The VCS view (phase 2), driven headlessly: installed through [Ui_state.create
   ~views] with test-only bindings, its git jobs run synchronously in isolated fixture
   repositories by [Vcs_driver]. Temp paths print as $DIR; commit hashes are
   reproducible. *)

open! Core
open Ches_screen
open Ches_input
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id
module Local_command = Ches_tile.Local_command
module Fixture = Ches_vcs_fixture.Fixture_repo
module Job = Ches_vcs.Job
module Event = Ches_vcs.Event

let vcs = Vcs_view.id

type env =
  { repo : Fixture.t
  ; width : int
  ; height : int
  }

let create ?(cwd : string option) ?(file = "a.txt") ?(text = "a\n") env =
  let leader_v c = [ Key.char ' '; Key.char 'v'; Key.char c ] in
  let bindings =
    Bindings.create
      (Bindings.to_list Bindings.default
       @ [ leader_v 'x', Bindings.Target.View (Focus_view vcs)
         ; leader_v 'X', View (Toggle_view vcs)
         ])
    |> Or_error.ok_exn
  in
  let path = Fixture.path env.repo file in
  let editor = Controller.editor (Ui_state.controller (Helpers.ui ~path text)) in
  Ui_state.create
    ~tiles_visible:false
    ~views:[ Vcs_view.entry ~cwd:(Option.value cwd ~default:env.repo.work) () ]
    (Controller.create ~keymap_config:{ Keymap.Config.default with normal = bindings } editor)
;;

let relative env text = String.substr_replace_all text ~pattern:env.repo.dir ~with_:"$DIR"
let settle env t = fst (Vcs_driver.settle env.repo t ~width:env.width ~height:env.height)

(* Keys, then every job they cause run to completion. *)
let run env t keys =
  settle env (Helpers.run ~width:env.width ~height:env.height t (Helpers.keys keys))
;;

(* Keys only: jobs stay queued. *)
let keys env t keys = Helpers.run ~width:env.width ~height:env.height t (Helpers.keys keys)
let state t = Option.value_exn (View_registry.find (Ui_state.views t) Vcs_view.key)

let screen env t =
  print_endline (relative env (Frame.to_string (Frame.render t ~width:env.width ~height:env.height)))
;;

let focused env t = View_id.to_string (Ui_state.focused_view t ~width:env.width ~height:env.height)

let with_env ?remote ?(width = 100) ?(height = 24) f =
  Fixture.with_repo ?remote (fun repo -> f { repo; width; height })
;;

let git env args = ignore (Fixture.git env.repo args : string)
let commit env message = ignore (Fixture.commit_all env.repo message : string)

(* A repository with a commit, then one file of each kind of change. *)
let changes env =
  Fixture.write env.repo "a.txt" "one\ntwo\nthree\n";
  Fixture.write env.repo "b.txt" "bee\n";
  Fixture.write env.repo "gone.txt" "bye\n";
  commit env "First";
  Fixture.write env.repo "a.txt" "one\nTWO\nthree\nfour\n";
  Fixture.write env.repo "b.txt" "bee\nsting\n";
  git env [ "add"; "b.txt" ];
  Fixture.write env.repo "new.txt" "fresh\n";
  git env [ "rm"; "-q"; "gone.txt" ]
;;

let%expect_test "wide: lists beside the diff, which follows the selection" =
  with_env (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    screen env t);
  [%expect {|
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main 10cf1ae                    │ 0 Diff: none                                             │|
    │                                       │ No diff for this row                                     │|
    │ 1 Files (4)                           │                                                          │|
    │ > - Untracked files (1)               │                                                          │|
    │   new.txt                             │                                                          │|
    │   - Unstaged changes (1)              │                                                          │|
    │   modified   a.txt                    │                                                          │|
    │   - Staged changes (2)                │                                                          │|
    │   modified   b.txt                    │                                                          │|
    │   deleted    gone.txt                 │                                                          │|
    │                                       │                                                          │|
    │                                       │                                                          │|
    │ 2 Branches (1)                        │                                                          │|
    │ > - Local branches (1)                │                                                          │|
    │   * main  First                       │                                                          │|
    │                                       │                                                          │|
    │ 3 Commits (1)                         │                                                          │|
    │ > - Recent commits (1)                │                                                          │|
    │   10cf1ae First                       │                                                          │|
    │                                       │                                                          │|
    ╰─ Files 1/7 ──────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: none
    |}]
;;

(* {2 Helpers for the remaining tests} *)

module Panel = Ches_vcs.Panel
module B = Ches_vcs_git.Backend

let position : Panel.Position.t option -> string = function
  | None -> "none"
  | Some (Header section) -> "header " ^ Panel.Section_id.to_string section
  | Some (Item { section; key }) -> sprintf "%s %S" (Panel.Section_id.to_string section) key
;;

let target (target : B.diff_target) = Sexp.to_string [%sexp (target : B.diff_target)]

let diff_state : Vcs_view.Diff_state.t -> string = function
  | Empty -> "empty"
  | No_diff -> "no diff"
  | Loading t -> "loading " ^ target t
  | Loaded (t, diff) -> sprintf "%s, %d file(s)" (target t) (List.length diff.files)
  | Failed (t, message) -> sprintf "failed %s: %s" (target t) message
;;

let focus_name focus = Sexp.to_string [%sexp (focus : Vcs_view.Focus.t)]

let describe t =
  let v = state t in
  printf
    "%s%s: %s; diff %s%s\n"
    (focus_name (Vcs_view.focus v))
    (if Vcs_view.Focus.equal (Vcs_view.focus v) Diff
     then sprintf " (follows %s)" (focus_name (Vcs_view.list_focus v))
     else "")
    (position (Vcs_view.cursor v (Vcs_view.list_focus v)).selected)
    (diff_state (Vcs_view.diff v))
    (if Vcs_view.loading v then " (loading)" else "")
;;

(* Keys, then run every job they cause, naming each. *)
let run_jobs env t keys_ =
  let t = keys env t keys_ in
  let t, ran = Vcs_driver.settle env.repo t ~width:env.width ~height:env.height in
  printf
    "ran: [%s]\n"
    (String.concat ~sep:"; " (List.map ran ~f:Vcs_driver.describe));
  t
;;

let top env t n =
  Frame.to_string (Frame.render t ~width:env.width ~height:env.height)
  |> String.split_lines
  |> Fn.flip List.take n
  |> List.iter ~f:(fun line -> print_endline (relative env line))
;;

let diff_view t = Option.value_exn (Vcs_view.text_view (state t))

let print_diff t =
  String.split_lines (Ches_tile.Text_view.text (diff_view t))
  |> List.iteri ~f:(fun i line -> printf "%2d|%s\n" i line)
;;

(* The diff cursor's line and byte column. *)
let diff_cursor t =
  let view = diff_view t in
  let text = Ches_tile.Text_view.text view in
  let cursor = Ches_tile.Text_view.cursor view in
  let before = String.prefix text cursor in
  let line = String.count before ~f:(Char.equal '\n') in
  let column =
    match String.rindex before '\n' with
    | None -> cursor
    | Some i -> cursor - i - 1
  in
  sprintf "line %d col %d%s" line column
    (match Ches_tile.Text_view.visual view with
     | None -> ""
     | Some Characterwise -> " visual"
     | Some Linewise -> " visual-line")
;;

let clipboard t =
  let t, text = Ui_state.take_clipboard t in
  printf "clipboard: %s\n" (Option.value_map text ~default:"(none)" ~f:(sprintf "%S"));
  t
;;

let notice t = printf "notice: %s\n" (Option.value (Ui_state.capture_notice t) ~default:"(none)")

let editor_at env t =
  let editor = Controller.editor (Ui_state.controller t) in
  printf
    "focused %s, file %s, line %d\n"
    (focused env t)
    (Option.value_map (Ches_core.Editor.path editor) ~default:"none" ~f:(relative env))
    (Ches_core.Editor.cursor_line editor + 1)
;;

let print_log env t =
  List.iter (Vcs_view.log (state t)) ~f:(fun (entry : Vcs_view.Log_entry.t) ->
    let words = String.split entry.command ~on:' ' in
    (* The subcommand is enough to tell entries apart. *)
    let command =
      List.find words ~f:(fun word ->
        List.mem
          [ "rev-parse"; "status"; "for-each-ref"; "log"; "diff"; "show" ]
          word
          ~equal:String.equal)
      |> Option.value ~default:(relative env entry.command)
    in
    printf
      "%s %s: %s%s%s\n"
      (Job.Id.to_string_hum entry.job)
      command
      (Option.value entry.status ~default:"running")
      (if entry.stale then " (stale)" else "")
      (String.concat (List.map entry.output ~f:(fun line -> " | " ^ relative env line))))
;;

let%expect_test "hidden, the view runs nothing; shown, it detects, refreshes and diffs" =
  with_env (fun env ->
    changes env;
    let t = create env in
    let t, jobs = Ui_state.take_vcs_jobs t in
    printf "jobs while hidden: %d\n" (List.length jobs);
    let t = run_jobs env t "l" in
    let t = run_jobs env t " vx" in
    describe t;
    (* Moving onto a file fetches its diff; the diff follows. *)
    let t = run_jobs env t "j" in
    describe t;
    screen env t);
  [%expect {|
    jobs while hidden: 0
    ran: []
    ran: [detect g1.1; refresh g1.2]
    Files: header untracked; diff no diff
    ran: [diff g1.3]
    Files: untracked "new.txt"; diff (Untracked new.txt), 1 file(s)
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main 10cf1ae                    │ 0 Diff: Untracked: new.txt                               │|
    │                                       │ diff --git a/new.txt b/new.txt                           │|
    │ 1 Files (4)                           │ new file mode 100644                                     │|
    │   - Untracked files (1)               │ index 0000000..92d5444                                   │|
    │ > new.txt                             │ --- /dev/null                                            │|
    │   - Unstaged changes (1)              │ +++ b/new.txt                                            │|
    │   modified   a.txt                    │ @@ -0,0 +1 @@                                            │|
    │   - Staged changes (2)                │ +fresh                                                   │|
    │   modified   b.txt                    │                                                          │|
    │   deleted    gone.txt                 │                                                          │|
    │                                       │                                                          │|
    │                                       │                                                          │|
    │ 2 Branches (1)                        │                                                          │|
    │ > - Local branches (1)                │                                                          │|
    │   * main  First                       │                                                          │|
    │                                       │                                                          │|
    │ 3 Commits (1)                         │                                                          │|
    │ > - Recent commits (1)                │                                                          │|
    │   10cf1ae First                       │                                                          │|
    │                                       │                                                          │|
    ╰─ Files 2/7 ──────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: none
    |}]
;;

let%expect_test "layout: side by side, stacked, single; the log at the bottom" =
  let show ~width ~rows ~focus ~log =
    let layout = Vcs_view.Layout.compute ~width ~rows ~focus ~log in
    let rect = function
      | None -> "-"
      | Some { Geometry.Rect.x; y; width; height } -> sprintf "%d,%d %dx%d" x y width height
    in
    printf
      "%3dx%-3d %-6s log=%-5b %-12s lists %-10s diff %-10s log %s\n"
      width
      rows
      (focus_name focus)
      log
      (Sexp.to_string [%sexp (layout.mode : Vcs_view.Layout.Mode.t)])
      (rect layout.lists)
      (rect layout.diff)
      (rect layout.log)
  in
  show ~width:200 ~rows:40 ~focus:Files ~log:false;
  show ~width:80 ~rows:20 ~focus:Files ~log:true;
  show ~width:79 ~rows:20 ~focus:Files ~log:false;
  show ~width:79 ~rows:16 ~focus:Diff ~log:false;
  show ~width:79 ~rows:15 ~focus:Files ~log:false;
  show ~width:79 ~rows:15 ~focus:Diff ~log:false;
  show ~width:79 ~rows:24 ~focus:Files ~log:true;
  show ~width:79 ~rows:11 ~focus:Diff ~log:true;
  show ~width:20 ~rows:1 ~focus:Files ~log:true;
  show ~width:0 ~rows:0 ~focus:Diff ~log:false;
  [%expect {|
    200x40  Files  log=false Side_by_side lists 0,0 60x40  diff 61,0 139x40 log -
     80x20  Files  log=true  Side_by_side lists 0,0 32x14  diff 33,0 47x14 log 0,14 80x6
     79x20  Files  log=false Stacked      lists 0,0 79x10  diff 0,11 79x9  log -
     79x16  Diff   log=false Stacked      lists 0,0 79x8   diff 0,9 79x7   log -
     79x15  Files  log=false Single       lists 0,0 79x15  diff -          log -
     79x15  Diff   log=false Single       lists -          diff 0,0 79x15  log -
     79x24  Files  log=true  Stacked      lists 0,0 79x8   diff 0,9 79x7   log 0,16 79x8
     79x11  Diff   log=true  Single       lists -          diff 0,0 79x11  log -
     20x1   Files  log=true  Single       lists 0,0 20x1   diff -          log -
      0x0   Diff   log=false Single       lists -          diff 0,0 0x0    log -
    |}]
;;

let%expect_test "stacked and single frames, in both focuses" =
  with_env ~width:60 ~height:40 (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    let t = run env t "jjj" in
    screen env t;
    let t = run env t "<Tab>" in
    top env t 3;
    let env = { env with height = 14 } in
    let t = run env t "" in
    screen env t;
    let t = run env t "<Tab>" in
    screen env t);
  [%expect {|
     1:a.txt [2:VCS: main]                                      |
    ╭─ VCS: work (main) ───────────────────────────────────────╮|
    │ Head: main 10cf1ae                                       │|
    │                                                          │|
    │ 1 Files (4)                                              │|
    │   - Untracked files (1)                                  │|
    │   new.txt                                                │|
    │   - Unstaged changes (1)                                 │|
    │ > modified   a.txt                                       │|
    │   - Staged changes (2)                                   │|
    │   modified   b.txt                                       │|
    │                                                          │|
    │ 2 Branches (1)                                           │|
    │ > - Local branches (1)                                   │|
    │   * main  First                                          │|
    │                                                          │|
    │ 3 Commits (1)                                            │|
    │ > - Recent commits (1)                                   │|
    │   10cf1ae First                                          │|
    │                                                          │|
    │ ──────────────────────────────────────────────────────── │|
    │  0 Diff: Unstaged: a.txt                                 │|
    │  diff --git a/a.txt b/a.txt                              │|
    │  index 4cb29ea..6addb9b 100644                           │|
    │  --- a/a.txt                                             │|
    │  +++ b/a.txt                                             │|
    │  @@ -1,3 +1,4 @@                                         │|
    │   one                                                    │|
    │  -two                                                    │|
    │  +TWO                                                    │|
    │   three                                                  │|
    │  +four                                                   │|
    │                                                          │|
    │                                                          │|
    │                                                          │|
    │                                                          │|
    │                                                          │|
    │                                                          │|
    ╰─ Files 4/7 ──────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                              |
    cursor: none
     1:a.txt [2:VCS: main]                                      |
    ╭─ VCS: work (main) ───────────────────────────────────────╮|
    │ Head: main 10cf1ae                                       │|
     1:a.txt [2:VCS: main]                                      |
    ╭─ VCS: work (main) ───────────────────────────────────────╮|
    │  0 Diff: Unstaged: a.txt                                 │|
    │  diff --git a/a.txt b/a.txt                              │|
    │  index 4cb29ea..6addb9b 100644                           │|
    │  --- a/a.txt                                             │|
    │  +++ b/a.txt                                             │|
    │  @@ -1,3 +1,4 @@                                         │|
    │   one                                                    │|
    │  -two                                                    │|
    │  +TWO                                                    │|
    │   three                                                  │|
    ╰─ Diff 1-9/10 ────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                              |
    cursor: 3,3 Block
     1:a.txt [2:VCS: main]                                      |
    ╭─ VCS: work (main) ───────────────────────────────────────╮|
    │ Head: main 10cf1ae                                       │|
    │ 1 Files (4)                                              │|
    │   - Untracked files (1)                                  │|
    │   new.txt                                                │|
    │   - Unstaged changes (1)                                 │|
    │ > modified   a.txt                                       │|
    │ 2 Branches (1)                                           │|
    │ > - Local branches (1)                                   │|
    │ 3 Commits (1)                                            │|
    │ > - Recent commits (1)                                   │|
    ╰─ Files 4/7 ──────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                              |
    cursor: none
    |}]
;;

let%expect_test "the command log, on and off" =
  with_env (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    let t = run env t "jjj@" in
    screen env t;
    print_log env t;
    let t = run env t "@" in
    printf "log visible: %b\n" (Vcs_view.log_visible (state t)));
  [%expect {|
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main 10cf1ae                    │ 0 Diff: Unstaged: a.txt                                  │|
    │                                       │ diff --git a/a.txt b/a.txt                               │|
    │ 1 Files (4)                           │ index 4cb29ea..6addb9b 100644                            │|
    │   - Untracked files (1)               │ --- a/a.txt                                              │|
    │   new.txt                             │ +++ b/a.txt                                              │|
    │   - Unstaged changes (1)              │ @@ -1,3 +1,4 @@                                          │|
    │ > modified   a.txt                    │  one                                                     │|
    │                                       │ -two                                                     │|
    │ 2 Branches (1)                        │ +TWO                                                     │|
    │ > - Local branches (1)                │  three                                                   │|
    │                                       │ +four                                                    │|
    │ 3 Commits (1)                         │                                                          │|
    │ > - Recent commits (1)                │                                                          │|
    │                                       │                                                          │|
    │ @ Command log (4)                                                                                │|
    │ [exit 0] git rev-parse --show-toplevel --absolute-git-dir                                        │|
    │ [exit 0] git status --porcelain=v2 -z --branch --untracked-files=all --find-renames              │|
    │ [exit 0] git for-each-ref '--format=%(refname:short)%00%(objectname)%00%(HEAD)%00%(upstream)%00> │|
    │ [exit 0] git log -z --no-color --no-show-signature --max-count=200 --format=%H%x00%P%x00%an%x00> │|
    │                                                                                                  │|
    ╰─ Files 4/7 ──────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: none
    g1.1 rev-parse: exit 0
    g1.2 status: exit 0
    g1.2 for-each-ref: exit 0
    g1.2 log: exit 0
    log visible: false
    |}]
;;

let%expect_test "panel and focus keys: 1 2 3 0 Tab Escape, moves, folds, Enter" =
  with_env (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    let step t keys_ =
      let t = run env t keys_ in
      printf "%-6s " keys_;
      describe t;
      t
    in
    let t = step t "2" in
    let t = step t "j" in
    let t = step t "3" in
    let t = step t "j" in
    let t = step t "0" in
    let t = step t "<Tab>" in
    let t = step t "<Tab>" in
    let t = step t "<Esc>" in
    let t = step t "1" in
    let t = step t "G" in
    let t = step t "gg" in
    let t = step t "k" in
    let t = step t "<C-d>" in
    let t = step t "<C-u>" in
    (* Enter folds the selected header, and unfolds it; on a file it focuses the
       diff. *)
    let t = step t "<CR>" in
    let rows t =
      let v = state t in
      let panel = List.hd_exn (Vcs_view.panels v) in
      printf "rows: %s\n"
        (String.concat ~sep:", "
           (List.map (Panel.Cursor.rows (Vcs_view.cursor v Files) panel) ~f:(fun p ->
              position (Some p))))
    in
    rows t;
    let t = step t "j" in
    let t = step t "<CR>" in
    rows t;
    let t = step t "j" in
    let t = step t "<CR>" in
    (* Enter on a branch checks it out (here refused: it is the current one); on a
       commit it focuses the diff. *)
    let t = step t "2j" in
    let t = run env t "<CR>" in
    notice t;
    let t = step t "3j<CR>" in
    ignore (t : Ui_state.t));
  [%expect {|
    2      Branches: header local; diff no diff
    j      Branches: local "main"; diff no diff
    3      Commits: header recent; diff no diff
    j      Commits: recent "10cf1aeab695c84699dfd610ebd22b42a8e06666"; diff (Commit 10cf1aeab695c84699dfd610ebd22b42a8e06666), 3 file(s)
    0      Diff (follows Commits): recent "10cf1aeab695c84699dfd610ebd22b42a8e06666"; diff (Commit 10cf1aeab695c84699dfd610ebd22b42a8e06666), 3 file(s)
    <Tab>  Commits: recent "10cf1aeab695c84699dfd610ebd22b42a8e06666"; diff (Commit 10cf1aeab695c84699dfd610ebd22b42a8e06666), 3 file(s)
    <Tab>  Diff (follows Commits): recent "10cf1aeab695c84699dfd610ebd22b42a8e06666"; diff (Commit 10cf1aeab695c84699dfd610ebd22b42a8e06666), 3 file(s)
    <Esc>  Commits: recent "10cf1aeab695c84699dfd610ebd22b42a8e06666"; diff (Commit 10cf1aeab695c84699dfd610ebd22b42a8e06666), 3 file(s)
    1      Files: header untracked; diff no diff
    G      Files: staged "gone.txt"; diff (Staged(gone.txt)), 1 file(s)
    gg     Files: header untracked; diff no diff
    k      Files: header untracked; diff no diff
    <C-d>  Files: header staged; diff (Staged()), 2 file(s)
    <C-u>  Files: header untracked; diff no diff
    <CR>   Files: header untracked; diff no diff
    rows: header untracked, header unstaged, unstaged "a.txt", header staged, staged "b.txt", staged "gone.txt"
    j      Files: header unstaged; diff (Unstaged()), 1 file(s)
    <CR>   Files: header unstaged; diff (Unstaged()), 1 file(s)
    rows: header untracked, header unstaged, header staged, staged "b.txt", staged "gone.txt"
    j      Files: header staged; diff (Staged()), 2 file(s)
    <CR>   Files: header staged; diff (Staged()), 2 file(s)
    2j     Branches: local "main"; diff no diff
    notice: Already on main; nothing ran
    3j<CR> Diff (follows Commits): recent "10cf1aeab695c84699dfd610ebd22b42a8e06666"; diff (Commit 10cf1aeab695c84699dfd610ebd22b42a8e06666), 3 file(s)
    |}]
;;

let%expect_test "y copies a path, a branch name, an abbreviated hash; q and Escape leave" =
  with_env (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    let t = run env t "y" in
    notice t;
    let t = clipboard t in
    let t = run env t "jjjy" in
    let t = clipboard t in
    let t = run env t "2jy" in
    let t = clipboard t in
    let t = run env t "3jy" in
    let t = clipboard t in
    (* Escape in a list is the host's return, which stays in an active view tab; q
       leaves through the view's own return. *)
    let t = run env t "<Esc>" in
    printf "after Escape: focused %s\n" (focused env t);
    let t = run env t "q" in
    printf
      "after q: focused %s, active tab %s\n"
      (focused env t)
      (Option.value_map (Ui_state.active_tab_view t) ~default:"none" ~f:View_id.to_string);
    let t = run env t " vx0q" in
    printf "q from the diff: focused %s\n" (focused env t));
  [%expect {|
    notice: VCS: nothing to copy
    clipboard: (none)
    clipboard: "a.txt"
    clipboard: "main"
    clipboard: "10cf1ae"
    after Escape: focused vcs
    after q: focused document, active tab none
    q from the diff: focused document
    |}]
;;

let%expect_test "g r refreshes; @ toggles the log; ? and the palette list the commands" =
  with_env (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    let t = run_jobs env t "gr" in
    let t = run_jobs env t "jgr" in
    describe t;
    let help t =
      match Ui_state.help t with
      | None -> print_endline "no help"
      | Some help ->
        List.iter (Help_tile.commands help) ~f:(fun command ->
          printf "%-8s %-15s %s\n" (Local_command.keys_hum command) command.name
            command.description)
    in
    let t = run env t "?" in
    help t;
    let t = run env t "<Esc><Tab>?" in
    help t;
    (* The palette lists the focused view's commands first, and runs them there. *)
    let t = run env t "<Esc><Tab> cc" in
    let palette = Palette_tile.palette (Option.value_exn (Ui_state.palette t)) in
    List.iter (List.take (Ches_palette.Palette.results palette) 4) ~f:(fun result ->
      print_endline
        (Ches_palette.Catalog.Id.to_string (Ches_palette.Catalog.Entry.id result.item)));
    let t = run env t "focus commits<CR>" in
    describe t);
  [%expect {|
    ran: [refresh g1.3]
    ran: [diff g1.4; refresh g1.5; diff g1.6]
    Files: untracked "new.txt"; diff (Untracked new.txt), 1 file(s)
    g r      refresh         Refresh
    @        toggle-log      Show or hide the command log
    q        leave           Leave the VCS view
    1        focus-files     Focus the Files panel
    2        focus-branches  Focus the Branches panel
    3        focus-commits   Focus the Commits panel
    0        focus-diff      Focus the diff
    Tab      toggle-diff     Focus the diff
    Enter    select          Focus the diff of the selection
    s        stage           Stage the file or section (a conflict: mark it resolved)
    u        unstage         Unstage the file or section
    x        discard         Discard the file's or section's changes; confirmed
    S        stage-all       Stage all changes (not conflicts)
    U        unstage-all     Unstage all changes
    c        commit          Commit, amend or extend (the commit popup)
    f        fetch           Fetch from the default remote, pruning gone branches
    p        pull            Pull from the upstream (the pull popup)
    P        push            Push the branch (the push popup)
    m        merge           Merge the branch selected in Branches (the merge popup)
    y        copy            Copy the file's path
    j        next            Select next item
    k        previous        Select previous item
    g g      first           Select first item
    G        last            Select last item
    Ctrl-d   half-page-down  Select half a page down
    Ctrl-u   half-page-up    Select half a page up
    g r      refresh         Refresh
    @        toggle-log      Show or hide the command log
    q        leave           Leave the VCS view
    Tab      toggle-diff     Back to the list
    e        open-file       Open the file at the cursor's line
    s        stage           Stage the hunk at the cursor (on a file header: the file)
    u        unstage         Unstage the hunk at the cursor (or the file)
    x        discard         Discard the hunk at the cursor (or the file); confirmed
    S        stage-all       Stage all changes (not conflicts)
    U        unstage-all     Unstage all changes
    ]        next-hunk       Next hunk
    [        previous-hunk   Previous hunk
    c        commit          Commit, amend or extend (the commit popup)
    f        fetch           Fetch from the default remote, pruning gone branches
    p        pull            Pull from the upstream (the pull popup)
    P        push            Push the branch (the push popup)
    m        merge           Merge the branch selected in Branches (the merge popup)
    j        cursor-down     Move down a row
    k        cursor-up       Move up a row
    w        word-forward    Move to the next word
    b        word-backward   Move to the previous word
    g g      cursor-first    Move to the first row
    G        cursor-last     Move to the last row
    v        visual          Start Visual selection
    V        visual-line     Start linewise Visual selection
    y y      copy-line       Copy the cursor's line
    local.vcs.refresh
    local.vcs.toggle-log
    local.vcs.leave
    local.vcs.focus-files
    Commits: header recent; diff no diff
    |}]
;;

let%expect_test "the diff follows the selection across files, headers and commits" =
  with_env (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    let t =
      List.fold [ "j"; "j"; "j"; "j"; "j"; "j"; "j"; "3"; "j"; "k"; "2"; "j"; "1" ]
        ~init:t
        ~f:(fun t keys_ ->
          let t = run_jobs env t keys_ in
          describe t;
          t)
    in
    (* A staged deletion, the staged header's combined diff, a commit's [show]. *)
    let t = run env t "G<Tab>" in
    print_diff t;
    let t = run env t "<Tab>k" in
    let t = run env t "kk<Tab>" in
    print_diff t;
    (* From the diff, digits are a count: Tab back to the lists for [3]. *)
    let t = run env t "<Tab>3j" in
    screen env t);
  [%expect {|
    ran: [diff g1.3]
    Files: untracked "new.txt"; diff (Untracked new.txt), 1 file(s)
    ran: [diff g1.4]
    Files: header unstaged; diff (Unstaged()), 1 file(s)
    ran: [diff g1.5]
    Files: unstaged "a.txt"; diff (Unstaged(a.txt)), 1 file(s)
    ran: [diff g1.6]
    Files: header staged; diff (Staged()), 2 file(s)
    ran: [diff g1.7]
    Files: staged "b.txt"; diff (Staged(b.txt)), 1 file(s)
    ran: [diff g1.8]
    Files: staged "gone.txt"; diff (Staged(gone.txt)), 1 file(s)
    ran: []
    Files: staged "gone.txt"; diff (Staged(gone.txt)), 1 file(s)
    ran: []
    Commits: header recent; diff no diff
    ran: [diff g1.9]
    Commits: recent "10cf1aeab695c84699dfd610ebd22b42a8e06666"; diff (Commit 10cf1aeab695c84699dfd610ebd22b42a8e06666), 3 file(s)
    ran: []
    Commits: header recent; diff no diff
    ran: []
    Branches: header local; diff no diff
    ran: []
    Branches: local "main"; diff no diff
    ran: [diff g1.10]
    Files: staged "gone.txt"; diff (Staged(gone.txt)), 1 file(s)
     0|diff --git a/gone.txt b/gone.txt
     1|deleted file mode 100644
     2|index b023018..0000000
     3|--- a/gone.txt
     4|+++ /dev/null
     5|@@ -1 +0,0 @@
     6|-bye
     0|diff --git a/a.txt b/a.txt
     1|index 4cb29ea..6addb9b 100644
     2|--- a/a.txt
     3|+++ b/a.txt
     4|@@ -1,3 +1,4 @@
     5| one
     6|-two
     7|+TWO
     8| three
     9|+four
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main 10cf1ae                    │ 0 Diff: Commit 10cf1ae                                   │|
    │                                       │ commit 10cf1aeab695c84699dfd610ebd22b42a8e06666          │|
    │ 1 Files (4)                           │ Author:     Ches Test <ches-test@example.invalid>        │|
    │   new.txt                             │ AuthorDate: 2026-01-01T00:00:00+00:00                    │|
    │   - Unstaged changes (1)              │ Commit:     Ches Test <ches-test@example.invalid>        │|
    │ > modified   a.txt                    │ CommitDate: 2026-01-01T00:00:00+00:00                    │|
    │                                       │                                                          │|
    │ 2 Branches (1)                        │     First                                                │|
    │   - Local branches (1)                │                                                          │|
    │ > * main  First                       │ diff --git a/a.txt b/a.txt                               │|
    │                                       │ new file mode 100644                                     │|
    │ 3 Commits (1)                         │ index 0000000..4cb29ea                                   │|
    │   - Recent commits (1)                │ --- /dev/null                                            │|
    │ > 10cf1ae First                       │ +++ b/a.txt                                              │|
    │                                       │ @@ -0,0 +1,3 @@                                          │|
    │                                       │ +one                                                     │|
    │                                       │ +two                                                     │|
    │                                       │ +three                                                   │|
    │                                       │ diff --git a/b.txt b/b.txt                               │|
    │                                       │ new file mode 100644                                     │|
    ╰─ Commits 2/2 ────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: none
    |}]
;;

let%expect_test "counts in the diff: 10j, 2k, 12G; digits switch panels only from a list" =
  with_env (fun env ->
    Fixture.write env.repo "a.txt" "a\n";
    commit env "First";
    Fixture.write env.repo "long.txt" (String.concat (List.init 30 ~f:(sprintf "line %d\n")));
    let t = run env (create env) " vx" in
    let t = run env t "j<Tab>" in
    let footer t =
      Frame.to_string (Frame.render t ~width:env.width ~height:env.height)
      |> String.split_lines
      |> Fn.flip List.nth_exn (env.height - 2)
      |> String.strip
      |> printf "footer: %s\n"
    in
    let step t keys_ =
      List.fold keys_ ~init:t ~f:(fun t keys_ ->
        let t = run env t keys_ in
        printf "%-6s " keys_;
        if Vcs_view.Focus.equal (Vcs_view.focus (state t)) Diff
        then printf "%s, " (diff_cursor t);
        describe t;
        t)
    in
    let t = step t [ "10j"; "2k"; "12G"; "3gg"; "100j"; "gg" ] in
    (* A pending count shows in the footer; the diff keeps focus. *)
    let t = keys env t "2" in
    footer t;
    let t = step t [ "j"; "1"; "0j" ] in
    (* Escape cancels a pending count. *)
    let t = keys env t "5" in
    footer t;
    let t = step t [ "<Esc>"; "j" ] in
    (* Back in the list, [2] focuses Branches. *)
    let (_ : Ui_state.t) = step t [ "<Tab>"; "2" ] in
    ());
  [%expect {|
    10j    line 10 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    2k     line 8 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    12G    line 11 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    3gg    line 2 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    100j   line 35 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    gg     line 0 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    footer: ╰─ Pending: 2 ─────────────────────────────────────────────────────────────────────────────────────╯|
    j      line 2 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    1      line 2 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    0j     line 12 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    footer: ╰─ Pending: 5 ─────────────────────────────────────────────────────────────────────────────────────╯|
    <Esc>  line 12 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    j      line 13 col 0, Diff (follows Files): untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    <Tab>  Files: untracked "long.txt"; diff (Untracked long.txt), 1 file(s)
    2      Branches: header local; diff no diff
    |}]
;;

let%expect_test "padding: a blank column each side of the diff, blank rows between panels" =
  with_env (fun env ->
    Fixture.write env.repo "a.txt" "a\n";
    commit env "First";
    Fixture.write env.repo "wide.txt" (String.make 70 'x' ^ "\n");
    let t = run env (create env) " vx" in
    let t = run env t "j" in
    screen env t;
    (* The text cursor follows the padding: [$] is the wrapped line's last glyph. *)
    let t = run env t "<Tab>G$" in
    printf "%s\n" (diff_cursor t);
    screen env t);
  [%expect {|
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main 0e161fa                    │ 0 Diff: Untracked: wide.txt                              │|
    │                                       │ diff --git a/wide.txt b/wide.txt                         │|
    │ 1 Files (1)                           │ new file mode 100644                                     │|
    │   - Untracked files (1)               │ index 0000000..4daaa81                                   │|
    │ > wide.txt                            │ --- /dev/null                                            │|
    │                                       │ +++ b/wide.txt                                           │|
    │                                       │ @@ -0,0 +1 @@                                            │|
    │                                       │ +xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  │|
    │                                       │ xxxxxxxxxxxxxxxx                                         │|
    │                                       │                                                          │|
    │                                       │                                                          │|
    │                                       │                                                          │|
    │ 2 Branches (1)                        │                                                          │|
    │ > - Local branches (1)                │                                                          │|
    │   * main  First                       │                                                          │|
    │                                       │                                                          │|
    │ 3 Commits (1)                         │                                                          │|
    │ > - Recent commits (1)                │                                                          │|
    │   0e161fa First                       │                                                          │|
    │                                       │                                                          │|
    ╰─ Files 2/2 ──────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: none
    line 6 col 70
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main 0e161fa                    │ 0 Diff: Untracked: wide.txt                              │|
    │                                       │ diff --git a/wide.txt b/wide.txt                         │|
    │ 1 Files (1)                           │ new file mode 100644                                     │|
    │   - Untracked files (1)               │ index 0000000..4daaa81                                   │|
    │ > wide.txt                            │ --- /dev/null                                            │|
    │                                       │ +++ b/wide.txt                                           │|
    │                                       │ @@ -0,0 +1 @@                                            │|
    │                                       │ +xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  │|
    │                                       │ xxxxxxxxxxxxxxxx                                         │|
    │                                       │                                                          │|
    │                                       │                                                          │|
    │                                       │                                                          │|
    │ 2 Branches (1)                        │                                                          │|
    │ > - Local branches (1)                │                                                          │|
    │   * main  First                       │                                                          │|
    │                                       │                                                          │|
    │ 3 Commits (1)                         │                                                          │|
    │ > - Recent commits (1)                │                                                          │|
    │   0e161fa First                       │                                                          │|
    │                                       │                                                          │|
    ╰─ Diff 1-8/8 ─────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: 57,10 Block
    |}]
;;

let%expect_test "the diff's text keys, Visual and copying; edits are refused" =
  with_env (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    let t = run env t "jjj<Tab>" in
    print_diff t;
    let t =
      List.fold
        [ "j"; "j"; "w"; "w"; "b"; "$"; "0"; "G"; "gg"; "<C-d>"; "<C-u>"; "jjjjjv"; "l" ]
        ~init:t
        ~f:(fun t keys_ ->
          let t = run env t keys_ in
          printf "%-6s %s\n" keys_ (diff_cursor t);
          t)
    in
    let t = run env t "y" in
    let t = clipboard t in
    let t = run env t "Vjy" in
    let t = clipboard t in
    let t = run env t "yy" in
    let t = clipboard t in
    let t = run env t "d" in
    notice t;
    (* Escape ends Visual, then goes back to the list. *)
    let t = run env t "v<Esc>" in
    printf "%s, " (diff_cursor t);
    describe t;
    let t = run env t "<Esc>" in
    describe t);
  [%expect {|
     0|diff --git a/a.txt b/a.txt
     1|index 4cb29ea..6addb9b 100644
     2|--- a/a.txt
     3|+++ b/a.txt
     4|@@ -1,3 +1,4 @@
     5| one
     6|-two
     7|+TWO
     8| three
     9|+four
    j      line 1 col 0
    j      line 2 col 0
    w      line 2 col 4
    w      line 2 col 5
    b      line 2 col 4
    $      line 2 col 10
    0      line 2 col 0
    G      line 9 col 0
    gg     line 0 col 0
    <C-d>  line 9 col 0
    <C-u>  line 0 col 0
    jjjjjv line 5 col 0 visual
    l      line 5 col 1 visual
    clipboard: " o"
    clipboard: " one\n-two\n"
    clipboard: " one\n"
    notice: VCS: read-only; edits unavailable
    line 5 col 0, Diff (follows Files): unstaged "a.txt"; diff (Unstaged(a.txt)), 1 file(s)
    Files: unstaged "a.txt"; diff (Unstaged(a.txt)), 1 file(s)
    |}]
;;

let%expect_test "e and Enter in the diff open the file at the line: +, -, context, headers" =
  with_env (fun env ->
    Fixture.write env.repo "a.txt" "one\ntwo\nthree\n";
    Fixture.write env.repo "z.txt" "x\ny\nz\n";
    Fixture.write env.repo "gone.txt" "bye\n";
    commit env "First";
    Fixture.write env.repo "a.txt" "one\nTWO\nthree\nfour\n";
    Fixture.write env.repo "z.txt" "x\n";
    git env [ "rm"; "-q"; "gone.txt" ];
    let t = run env (create env ~file:"z.txt" ~text:"x\n") " vx" in
    (* Unstaged: a.txt, z.txt; then the staged deletion. *)
    let t = run env t "j<CR>" in
    print_diff t;
    (* Back to the VCS tab (the open file replaced it), then to a line. *)
    let back t = if String.equal (focused env t) "vcs" then t else run env t " vx" in
    let open_at t line keys_ =
      let t = run env (back t) ("gg" ^ String.concat (List.init line ~f:(fun _ -> "j")) ^ keys_) in
      printf "line %2d %-4s -> " line keys_;
      editor_at env t;
      t
    in
    let t = open_at t 0 "e" in
    let t = open_at t 4 "e" in
    let t = open_at t 5 "e" in
    let t = open_at t 6 "<CR>" in
    let t = open_at t 7 "e" in
    let t = open_at t 8 "e" in
    let t = open_at t 9 "e" in
    (* z.txt lost its last lines: a removed line with no new-side line after it in
       its hunk opens at the hunk's new start. *)
    let t = run env (back t) "<Tab>j<CR>" in
    print_diff t;
    let t = open_at t 5 "e" in
    let t = open_at t 6 "e" in
    let t = open_at t 7 "e" in
    (* A deleted file has nothing to open. *)
    let t = run env (back t) "<Tab>jj<CR>" in
    print_diff t;
    let t = run env t "Ge" in
    notice t;
    editor_at env t;
    (* A commit's diff opens the work-tree file at the commit's line numbers. *)
    let t = run env t "<Tab>3j<CR>" in
    let t = run env t "G<CR>" in
    editor_at env t);
  [%expect {|
     0|diff --git a/a.txt b/a.txt
     1|index 4cb29ea..6addb9b 100644
     2|--- a/a.txt
     3|+++ b/a.txt
     4|@@ -1,3 +1,4 @@
     5| one
     6|-two
     7|+TWO
     8| three
     9|+four
    line  0 e    -> focused document, file $DIR/work/a.txt, line 1
    line  4 e    -> focused document, file $DIR/work/a.txt, line 1
    line  5 e    -> focused document, file $DIR/work/a.txt, line 1
    line  6 <CR> -> focused document, file $DIR/work/a.txt, line 2
    line  7 e    -> focused document, file $DIR/work/a.txt, line 2
    line  8 e    -> focused document, file $DIR/work/a.txt, line 3
    line  9 e    -> focused document, file $DIR/work/a.txt, line 4
     0|diff --git a/z.txt b/z.txt
     1|index 04ec35a..587be6b 100644
     2|--- a/z.txt
     3|+++ b/z.txt
     4|@@ -1,3 +1 @@
     5| x
     6|-y
     7|-z
    line  5 e    -> focused document, file $DIR/work/z.txt, line 1
    line  6 e    -> focused document, file $DIR/work/z.txt, line 1
    line  7 e    -> focused document, file $DIR/work/z.txt, line 1
     0|diff --git a/gone.txt b/gone.txt
     1|deleted file mode 100644
     2|index b023018..0000000
     3|--- a/gone.txt
     4|+++ /dev/null
     5|@@ -1 +0,0 @@
     6|-bye
    notice: gone.txt was deleted: nothing to open
    focused vcs, file $DIR/work/z.txt, line 1
    focused document, file $DIR/work/z.txt, line 2
    |}]
;;

(* Two branches whose merge conflicts in every way git can. *)
let conflicting_branches env =
  let write = Fixture.write env.repo in
  write "uu.txt" "base\n";
  write "ud.txt" "base\n";
  write "du.txt" "base\n";
  commit env "base";
  git env [ "checkout"; "-q"; "-b"; "other" ];
  write "uu.txt" "theirs\n";
  git env [ "rm"; "-q"; "ud.txt" ];
  write "du.txt" "theirs\n";
  write "aa.txt" "theirs\n";
  commit env "other";
  git env [ "checkout"; "-q"; "main" ];
  write "uu.txt" "ours\n";
  write "ud.txt" "ours\n";
  git env [ "rm"; "-q"; "du.txt" ];
  write "aa.txt" "ours\n";
  commit env "main"
;;

(* Run git expecting it to fail (a conflict). *)
let git_fails env args =
  let result =
    Fixture.run env.repo (Ches_vcs.Exec.Spec.create ~kind:Mutate ~cwd:env.repo.work "git" args)
  in
  printf "git %s: %s\n" (String.concat ~sep:" " args) (Ches_vcs.Exec.Result.status_hum result)
;;

let%expect_test "a conflict: the section, its combined diff, conflict markers, header-only files" =
  with_env (fun env ->
    conflicting_branches env;
    git_fails env [ "merge"; "-q"; "other" ];
    let t = run env (create env) " vx" in
    screen env t;
    let t = run env t "<Tab>" in
    print_diff t;
    (* A combined line opens the work-tree file at its result line. *)
    let t = run env t "<Tab>j<Tab>" in
    print_diff t;
    let t = run env t "Gk<CR>" in
    editor_at env t;
    let t = run env t " vx<Tab>jj<Tab>" in
    print_diff t);
  [%expect {|
    git merge -q other: exit 1
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main 1d0798b                    │ 0 Diff: Conflicted: aa.txt, du.txt, ud.txt, uu.txt       │|
    │ Merging 1cca8e7 (m m commits, m a abo>│ diff --cc aa.txt                                         │|
    │                                       │ index b19a1e9,950b81b..0000000                           │|
    │ 1 Files (4)                           │ --- a/aa.txt                                             │|
    │ > - Conflicted (4)                    │ +++ b/aa.txt                                             │|
    │   both added      aa.txt              │ @@@ -1,1 -1,1 +1,5 @@@                                   │|
    │   deleted by us   du.txt              │ ++<<<<<<< HEAD                                           │|
    │   deleted by them ud.txt              │  +ours                                                   │|
    │   both modified   uu.txt              │ ++=======                                                │|
    │                                       │ + theirs                                                 │|
    │                                       │ ++>>>>>>> other                                          │|
    │                                       │ diff --cc uu.txt                                         │|
    │ 2 Branches (2)                        │ index b19a1e9,950b81b..0000000                           │|
    │ > - Local branches (2)                │ --- a/uu.txt                                             │|
    │   * main  main                        │ +++ b/uu.txt                                             │|
    │                                       │ @@@ -1,1 -1,1 +1,5 @@@                                   │|
    │ 3 Commits (2)                         │ ++<<<<<<< HEAD                                           │|
    │ > - Recent commits (2)                │  +ours                                                   │|
    │   1d0798b main                        │ ++=======                                                │|
    │                                       │ + theirs                                                 │|
    ╰─ Files 1/5 ──────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: none
     0|diff --cc aa.txt
     1|index b19a1e9,950b81b..0000000
     2|--- a/aa.txt
     3|+++ b/aa.txt
     4|@@@ -1,1 -1,1 +1,5 @@@
     5|++<<<<<<< HEAD
     6| +ours
     7|++=======
     8|+ theirs
     9|++>>>>>>> other
    10|diff --cc uu.txt
    11|index b19a1e9,950b81b..0000000
    12|--- a/uu.txt
    13|+++ b/uu.txt
    14|@@@ -1,1 -1,1 +1,5 @@@
    15|++<<<<<<< HEAD
    16| +ours
    17|++=======
    18|+ theirs
    19|++>>>>>>> other
    20|* Unmerged path du.txt
    21|* Unmerged path ud.txt
     0|diff --cc aa.txt
     1|index b19a1e9,950b81b..0000000
     2|--- a/aa.txt
     3|+++ b/aa.txt
     4|@@@ -1,1 -1,1 +1,5 @@@
     5|++<<<<<<< HEAD
     6| +ours
     7|++=======
     8|+ theirs
     9|++>>>>>>> other
    focused document, file $DIR/work/aa.txt, line 4
     0|* Unmerged path ud.txt
    |}]
;;

let%expect_test "a rebase in progress, then a detached HEAD" =
  with_env ~height:12 (fun env ->
    conflicting_branches env;
    git_fails env [ "rebase"; "other" ];
    let t = run env (create env) " vx" in
    top env t 6;
    git env [ "rebase"; "--abort" ];
    git env [ "checkout"; "-q"; "--detach"; "HEAD~1" ];
    let t = run env t "gr" in
    top env t 4);
  [%expect {|
    git rebase other: exit 1
     1:a.txt [2:VCS]                                                                                    |
    ╭─ VCS: work (detached at 1cca8e7) ────────────────────────────────────────────────────────────────╮|
    │ Head: detached at 1cca8e7             │ 0 Diff: Conflicted: aa.txt, du.txt, ud.txt, uu.txt       │|
    │ Rebasing main onto 1cca8e7 (r r conti>│ diff --cc aa.txt                                         │|
    │                                       │ index 950b81b,b19a1e9..0000000                           │|
    │ 1 Files (4)                           │ --- a/aa.txt                                             │|
     1:a.txt [2:VCS: 7b0842b]                                                                           |
    ╭─ VCS: work (detached at 7b0842b) ────────────────────────────────────────────────────────────────╮|
    │ Head: detached at 7b0842b             │ 0 Diff                                                   │|
    │                                       │                                                          │|
    |}]
;;

let%expect_test "upstreams: ahead and behind, in sync, gone" =
  with_env ~remote:true ~height:20 (fun env ->
    Fixture.write env.repo "f.txt" "1\n";
    commit env "One";
    git env [ "push"; "-q"; "-u"; "origin"; "main" ];
    Fixture.write env.repo "f.txt" "2\n";
    commit env "Two";
    git env [ "push"; "-q" ];
    git env [ "reset"; "-q"; "--hard"; "HEAD~1" ];
    Fixture.write env.repo "g.txt" "3\n";
    commit env "Three";
    git env [ "branch"; "--track"; "in-sync"; "origin/main" ];
    git env [ "push"; "-q"; "origin"; "main:doomed" ];
    git env [ "branch"; "--track"; "doomed"; "origin/doomed" ];
    git env [ "push"; "-q"; "origin"; ":doomed" ];
    git env [ "fetch"; "-q"; "--prune" ];
    let t = run env (create env) " vx" in
    let t = run env t "2" in
    screen env t;
    git env [ "checkout"; "-q"; "doomed" ];
    let t = run env t "gr" in
    top env t 4);
  [%expect {|
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main 5cd767d                    │ 0 Diff: none                                             │|
    │ Upstream: origin/main, ahead 1, behin>│ No diff for this row                                     │|
    │                                       │                                                          │|
    │ 1 Files (0)                           │                                                          │|
    │                                       │                                                          │|
    │ 2 Branches (3)                        │                                                          │|
    │ > - Local branches (3)                │                                                          │|
    │     doomed [origin/doomed: gone]  Thr>│                                                          │|
    │     in-sync [origin/main]  Two        │                                                          │|
    │   * main [origin/main: ahead 1, behin>│                                                          │|
    │                                       │                                                          │|
    │                                       │                                                          │|
    │                                       │                                                          │|
    │ 3 Commits (2)                         │                                                          │|
    │ > - Recent commits (2)                │                                                          │|
    │                                       │                                                          │|
    ╰─ Branches 1/4 ───────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: none
     1:a.txt [2:VCS: doomed]                                                                            |
    ╭─ VCS: work (doomed) ─────────────────────────────────────────────────────────────────────────────╮|
    │ Head: doomed 5cd767d                  │ 0 Diff: none                                             │|
    │ Upstream: origin/doomed (gone)        │ No diff for this row                                     │|
    |}]
;;

let%expect_test "not a repository, and no work tree: said plainly; g r looks again" =
  with_env ~height:12 (fun env ->
    let plain = Fixture.plain_dir env.repo "plain" in
    let t = run env (create env ~cwd:plain) " vx" in
    screen env t;
    printf "%s\n" (Sexp.to_string [%sexp (Vcs_view.repository (state t) : Vcs_view.Repository_state.t)]
                   |> relative env);
    let t = run env t "j" in
    notice t;
    let t = run env t "?" in
    List.iter (Help_tile.commands (Option.value_exn (Ui_state.help t))) ~f:(fun command ->
      printf "%s %s\n" (Local_command.keys_hum command) command.name);
    let t = run_jobs env t "<Esc>gr" in
    let t = run env t "@" in
    screen env t);
  with_env ~height:10 (fun env ->
    let t = run env (create env ~cwd:(env.repo.work ^ "/.git")) " vx" in
    screen env t);
  [%expect {|
     1:a.txt [2:VCS]                                                                                    |
    ╭─ VCS: not a repository ──────────────────────────────────────────────────────────────────────────╮|
    │ Not a git repository:                                                                            │|
    │ $DIR/plain                                         │|
    │                                                                                                  │|
    │ g r looks again; q leaves                                                                        │|
    │                                                                                                  │|
    │                                                                                                  │|
    │                                                                                                  │|
    │                                                                                                  │|
    ╰──────────────────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS VCS focused                                                                            |
    cursor: none
    (Not_a_repository(cwd $DIR/plain))
    notice: VCS: s/u/x stage/unstage/discard, c commit, m merge, f/p/P fetch/pull/push, 1/2/3 panels, Tab diff, g r refresh, @ log, q leaves, ? help
    g r refresh
    @ toggle-log
    q leave
    ran: [detect g2.2]
     1:a.txt [2:VCS]                                                                                    |
    ╭─ VCS: not a repository ──────────────────────────────────────────────────────────────────────────╮|
    │ Not a git repository:                                                                            │|
    │ $DIR/plain                                         │|
    │                                                                                                  │|
    │ g r looks again; q leaves                                                                        │|
    │                                                                                                  │|
    │                                                                                                  │|
    │                                                                                                  │|
    │                                                                                                  │|
    ╰──────────────────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS VCS: s/u/x stage/unstage/discard, c commit, m merge, f/p/P fetch/pull/push, 1/2/3 pan> |
    cursor: none
     1:a.txt [2:VCS]                                                                                    |
    ╭─ VCS: no work tree ──────────────────────────────────────────────────────────────────────────────╮|
    │ No work tree here:                                                                               │|
    │ $DIR/work/.git                                     │|
    │ fatal: this operation must be run in a work tree                                                 │|
    │                                                                                                  │|
    │ g r looks again; q leaves                                                                        │|
    │                                                                                                  │|
    ╰──────────────────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS VCS focused                                                                            |
    cursor: none
    |}]
;;

let%expect_test "stale reports are logged but never applied" =
  with_env (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    (* Two refreshes in flight; the repository changes between them; the older one's
       report arrives last. *)
    let t = keys env t "gr" in
    let t, first = Ui_state.take_vcs_jobs t in
    let t = keys env t "gr" in
    let t, second = Ui_state.take_vcs_jobs t in
    let feed t jobs =
      Helpers.run ~width:env.width ~height:env.height t
        (List.concat_map jobs ~f:(Vcs_driver.events env.repo)
         |> List.map ~f:(fun event -> Ui_state.Input.Vcs event))
    in
    let t = feed t second in
    Fixture.write env.repo "later.txt" "late\n";
    let t = feed t first in
    let t = settle env t in
    let files = List.hd_exn (Vcs_view.panels (state t)) in
    printf "untracked: %s\n"
      (String.concat ~sep:", "
         (List.concat_map files.sections ~f:(fun section ->
            if String.equal (Panel.Section_id.to_string section.id) "untracked"
            then List.map section.items ~f:(fun item -> item.key)
            else [])));
    print_log env t;
    (* A new generation (closed and reopened) makes everything in flight stale. *)
    let t = keys env t " vX vx" in
    let t, old_generation = Ui_state.take_vcs_jobs t in
    let t = keys env t " vX vx" in
    let t = feed t old_generation in
    describe t;
    let t = settle env t in
    describe t;
    printf "stamps generation %d\n" (Ches_vcs.Stamps.generation (Vcs_view.stamps (state t))));
  [%expect {|
    untracked: new.txt
    g1.1 rev-parse: exit 0
    g1.2 status: exit 0
    g1.2 for-each-ref: exit 0
    g1.2 log: exit 0
    g1.4 status: exit 0
    g1.4 for-each-ref: exit 0
    g1.4 log: exit 0
    g1.3 status: exit 0 (stale)
    g1.3 for-each-ref: exit 0 (stale)
    g1.3 log: exit 0 (stale)
    Files: header untracked; diff no diff (loading)
    Files: header untracked; diff no diff
    stamps generation 3
    |}]
;;

let%expect_test "selection identity across refreshes, and the removed-item rule" =
  with_env (fun env ->
    List.iter [ "a.txt"; "c.txt"; "d.txt" ] ~f:(fun file -> Fixture.write env.repo file "1\n");
    commit env "One";
    Fixture.write env.repo "old.txt" "old\n";
    commit env "Two";
    List.iter [ "a.txt"; "c.txt"; "d.txt" ] ~f:(fun file -> Fixture.write env.repo file "2\n");
    let t = run env (create env) " vx" in
    let step t ~stage keys_ =
      Option.iter stage ~f:(fun file -> git env [ "add"; file ]);
      let t = run env t keys_ in
      printf "%-14s " (Option.value_map stage ~default:keys_ ~f:(fun f -> "stage " ^ f));
      describe t;
      t
    in
    let t = step t ~stage:None "jj" in
    (* The selected file moves to Staged: the next item of its section. *)
    let t = step t ~stage:(Some "c.txt") "gr" in
    (* No next item: the previous one. *)
    let t = step t ~stage:(Some "d.txt") "gr" in
    (* Its section gone: the header of the next section that still exists. *)
    let t = step t ~stage:(Some "a.txt") "gr" in
    (* A commit stays selected while newer ones push it down. *)
    let t = step t ~stage:None "3G" in
    git env [ "commit"; "-q"; "-m"; "Three" ];
    let t = step t ~stage:None "gr" in
    ignore (t : Ui_state.t));
  [%expect {|
    jj             Files: unstaged "c.txt"; diff (Unstaged(c.txt)), 1 file(s)
    stage c.txt    Files: unstaged "d.txt"; diff (Unstaged(d.txt)), 1 file(s)
    stage d.txt    Files: unstaged "a.txt"; diff (Unstaged(a.txt)), 1 file(s)
    stage a.txt    Files: header staged; diff (Staged()), 3 file(s)
    3G             Commits: recent "40fa40da8d836550978c2281e7e5e4aea3d15e06"; diff (Commit 40fa40da8d836550978c2281e7e5e4aea3d15e06), 3 file(s)
    gr             Commits: recent "40fa40da8d836550978c2281e7e5e4aea3d15e06"; diff (Commit 40fa40da8d836550978c2281e7e5e4aea3d15e06), 3 file(s)
    |}]
;;

let%expect_test "a save under the repository refreshes once; others do not" =
  with_env (fun env ->
    changes env;
    let t = run env (create env ~file:"a.txt" ~text:"one\nTWO\nthree\nfour\n") " vx" in
    (* Back to the file tab, edit, save. *)
    let t = run env t "q" in
    let t = run_jobs env t "Ofive<Esc> w" in
    let t = run env t " vx" in
    describe t);
  with_env (fun env ->
    changes env;
    let outside = Fixture.plain_dir env.repo "outside" in
    let leader_v c = [ Key.char ' '; Key.char 'v'; Key.char c ] in
    let bindings =
      Bindings.create
        (Bindings.to_list Bindings.default
         @ [ leader_v 'x', Bindings.Target.View (Focus_view vcs) ])
      |> Or_error.ok_exn
    in
    let editor =
      Controller.editor (Ui_state.controller (Helpers.ui ~path:(outside ^ "/o.txt") "o\n"))
    in
    let t =
      Ui_state.create ~tiles_visible:false
        ~views:[ Vcs_view.entry ~cwd:env.repo.work () ]
        (Controller.create ~keymap_config:{ Keymap.Config.default with normal = bindings }
           editor)
    in
    let t = run env t " vxq" in
    let _ = run_jobs env t "ix<Esc> w" in
    ());
  [%expect {|
    ran: [refresh g1.3]
    Files: header untracked; diff no diff
    ran: []
    |}]
;;

let%expect_test "a truncated file, and a diff cut at its output limit" =
  with_env ~height:14 (fun env ->
    let lines f = String.concat (List.init 3000 ~f) in
    Fixture.write env.repo "huge.txt" (lines (sprintf "line %d\n"));
    commit env "Huge";
    Fixture.write env.repo "huge.txt"
      (lines (fun i -> if i % 10 = 5 then sprintf "changed %d\n" i else sprintf "line %d\n" i));
    let t = run env (create env) " vx" in
    let t = run env t "j<CR>G" in
    let text = Ches_tile.Text_view.text (diff_view t) in
    printf "%d lines\n" (List.length (String.split_lines text));
    screen env t;
    (* The same diff, run with a tiny output limit. *)
    let t = keys env t "<Tab>gr" in
    let t, refresh = Vcs_driver.step env.repo t ~width:env.width ~height:env.height in
    printf "%s\n" (String.concat ~sep:"; " (List.map refresh ~f:Vcs_driver.describe));
    let t, diffs = Ui_state.take_vcs_jobs t in
    let cut (job : Job.t) =
      Job.create ~id:job.id ?lane:job.lane
        (List.map job.steps ~f:(function
           | Run spec -> Job.Step.Run { spec with stdout_limit = 400 }
           | step -> step))
      |> Or_error.ok_exn
    in
    let t =
      Helpers.run ~width:env.width ~height:env.height t
        (List.concat_map diffs ~f:(fun job -> Vcs_driver.events env.repo (cut job))
         |> List.map ~f:(fun event -> Ui_state.Input.Vcs event))
    in
    describe t;
    let t = run env t "<Tab>" in
    print_diff t);
  [%expect {|
    2255 lines
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main c06e27f                    │ 0 Diff: Unstaged: huge.txt                               │|
    │ 1 Files (1)                           │  line 2492                                               │|
    │   - Unstaged changes (1)              │  line 2493                                               │|
    │ > modified   huge.txt                 │  line 2494                                               │|
    │                                       │ -line 2495                                               │|
    │                                       │ +changed 2495                                            │|
    │ 2 Branches (1)                        │  line 2496                                               │|
    │ > - Local branches (1)                │  line 2497                                               │|
    │ 3 Commits (1)                         │  line 2498                                               │|
    │ > - Recent commits (1)                │ ... 50 more hunks (400 lines) not shown                  │|
    ╰─ Diff 2247-2255/2255 ────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: 42,11 Block
    refresh g1.5
    Files: unstaged "huge.txt"; diff (Unstaged(huge.txt)), 1 file(s)
     0|diff --git a/huge.txt b/huge.txt
     1|index 2b2535c..0da8039 100644
     2|--- a/huge.txt
     3|+++ b/huge.txt
     4|@@ -3,7 +3,7 @@ line 1
     5| line 2
     6| line 3
     7| line 4
     8|-line 5
     9|+changed 5
    10| line 6
    11| line 7
    12| line 8
    13|@@ -13,7 +13,7 @@ line 11
    14| line 12
    15| line 13
    16| line 14
    17|-line 15
    18|+changed 15
    19| line 16
    20| line 17
    21| line 18
    22|@@ -23,7 +23,7 @@ line 21
    23| line 22
    24| line 23
    25| line 24
    26|-line 25
    27|+changed 25
    28| line 26
    29| line 27
    30| line 28
    31|... the diff output was cut inside this file
    32|(the diff output was cut at its size limit)
    |}]
;;

let%expect_test "paths with spaces, unicode and control bytes are escaped for display" =
  with_env ~height:16 (fun env ->
    Fixture.write env.repo "plain.txt" "p\n";
    commit env "One";
    List.iter [ "with space.txt"; "ünïcødé.txt"; "ctl\001\027.txt"; "line\nbreak.txt" ]
      ~f:(fun file -> Fixture.write env.repo file "x\n");
    let t = run env (create env) " vx" in
    let t = run env t "j" in
    screen env t;
    let t = run env t "<Tab>" in
    print_diff t;
    let t = run env t "<Tab>Gy" in
    ignore (clipboard t : Ui_state.t));
  [%expect {|
     1:a.txt [2:VCS: main]                                                                              |
    ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
    │ Head: main c17d7cb                    │ 0 Diff: Untracked: ctl^A^[.txt                           │|
    │ 1 Files (4)                           │ diff --git "a/ctl\001\033.txt" "b/ctl\001\033.txt"       │|
    │   - Untracked files (4)               │ new file mode 100644                                     │|
    │ > ctl^A^[.txt                         │ index 0000000..587be6b                                   │|
    │   line^Jbreak.txt                     │ --- /dev/null                                            │|
    │   with space.txt                      │ +++ "b/ctl\001\033.txt"                                  │|
    │ 2 Branches (1)                        │ @@ -0,0 +1 @@                                            │|
    │ > - Local branches (1)                │ +x                                                       │|
    │   * main  One                         │                                                          │|
    │ 3 Commits (1)                         │                                                          │|
    │ > - Recent commits (1)                │                                                          │|
    │   c17d7cb One                         │                                                          │|
    ╰─ Files 2/5 ──────────────────────────────────────────────────────────────────────────────────────╯|
     NORMAL  VCS: main VCS focused                                                                      |
    cursor: none
     0|diff --git "a/ctl\001\033.txt" "b/ctl\001\033.txt"
     1|new file mode 100644
     2|index 0000000..587be6b
     3|--- /dev/null
     4|+++ "b/ctl\001\033.txt"
     5|@@ -0,0 +1 @@
     6|+x
    clipboard: "\195\188n\195\175c\195\184d\195\169.txt"
    |}]
;;

let%expect_test "diff lines are styled by kind" =
  with_env ~width:84 ~height:16 (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    let t = run env t "jjj" in
    Frame.to_string_styled (Frame.render t ~width:env.width ~height:env.height)
    |> String.split_lines
    |> List.iter ~f:(fun line ->
      match String.substr_index line ~pattern:"│" with
      | Some _ -> print_endline (relative env line)
      | None -> ()));
  [%expect {|
    Border_focused[│] Status[ Head: main 10cf1ae              ] Border[│] Status[ ] Title[0 Diff: Unstaged: a.txt] Status[                        ] Border_focused[│]
    Border_focused[│] Status[ ] Pending[1 Files (4)] Status[                     ] Border[│] Status[ ] Diff_meta[diff --git a/a.txt b/a.txt                   ] Status[  ] Border_focused[│]
    Border_focused[│] Status[ ] Diff_meta[  - Untracked files (1)] Status[         ] Border[│] Status[ ] Diff_meta[index 4cb29ea..6addb9b 100644                ] Status[  ] Border_focused[│]
    Border_focused[│] Status[   new.txt                       ] Border[│] Status[ ] Diff_meta[--- a/a.txt                                  ] Status[  ] Border_focused[│]
    Border_focused[│] Status[ ] Diff_meta[  - Unstaged changes (1)] Status[        ] Border[│] Status[ ] Diff_meta[+++ b/a.txt                                  ] Status[  ] Border_focused[│]
    Border_focused[│] Status[ > modified   a.txt              ] Border[│] Status[ ] Diff_hunk[@@ -1,3 +1,4 @@                              ] Status[  ] Border_focused[│]
    Border_focused[│] Status[ ] Title[2 Branches (1)] Status[                  ] Border[│] Status[  one                                           ] Border_focused[│]
    Border_focused[│] Status[ ] Diff_meta[> - Local branches (1)] Status[          ] Border[│] Status[ ] Diff_removed[-two                                         ] Status[  ] Border_focused[│]
    Border_focused[│] Status[   * main  First                 ] Border[│] Status[ ] Diff_added[+TWO                                         ] Status[  ] Border_focused[│]
    Border_focused[│] Status[ ] Title[3 Commits (1)] Status[                   ] Border[│] Status[  three                                         ] Border_focused[│]
    Border_focused[│] Status[ ] Diff_meta[> - Recent commits (1)] Status[          ] Border[│] Status[ ] Diff_added[+four                                        ] Status[  ] Border_focused[│]
    Border_focused[│] Status[   10cf1ae First                 ] Border[│] Status[                                                ] Border_focused[│]
    |}]
;;
