(* The VCS view's log and history browsing (phase 8) end to end: the default bindings
   ([l] and its popup in the list panels, [+] in Commits, [\}] [\{] and Enter in the
   diff, [Space g l] from a buffer), git run synchronously by [Vcs_driver] in a fixture
   repository with a merged side branch, an unmerged branch and a rename. The graph
   rows are [Ches_vcs.Graph]'s; the commit file list is [Vcs_diff_text]'s. Paths under
   the fixture print as $DIR; commit hashes are reproducible. *)

open! Core
open Ches_screen
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id
module Text_view = Ches_tile.Text_view
module Fixture = Ches_vcs_fixture.Fixture_repo

let width = 100
let height = 40

let git ?cwd repo args = ignore (Fixture.git ?cwd repo args : string)
let commit repo message = ignore (Fixture.commit_all repo message : string)

(* History, oldest first: "one" (a.txt, z.txt); "side work" on [side]; "two" (a.txt
   and z.txt) on main; "Merge side"; "rename" (a.txt -> b.txt); "edit b". Branch
   [other] forks at "one" with "other work", never merged. Tag [v1] on "two". *)
let with_history f =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "a.txt" "1\n";
    Fixture.write repo "z.txt" "z\n";
    commit repo "one";
    git repo [ "branch"; "other" ];
    git repo [ "switch"; "-q"; "-c"; "side" ];
    Fixture.write repo "side.txt" "s\n";
    commit repo "side work";
    git repo [ "switch"; "-q"; "other" ];
    Fixture.write repo "other.txt" "o\n";
    commit repo "other work";
    git repo [ "switch"; "-q"; "main" ];
    Fixture.write repo "a.txt" "1\n2\n";
    Fixture.write repo "z.txt" "z\nzz\n";
    commit repo "two";
    git repo [ "tag"; "v1" ];
    git repo [ "merge"; "-q"; "--no-ff"; "-m"; "Merge side"; "side" ];
    git repo [ "mv"; "a.txt"; "b.txt" ];
    commit repo "rename";
    Fixture.write repo "b.txt" "1\n2\n3\n";
    commit repo "edit b";
    f repo)
;;

let last_message = ref ""

let create ?(file = "b.txt") ?path (repo : Fixture.t) =
  last_message := "";
  let path = Option.value path ~default:(Fixture.path repo file) in
  let controller =
    Controller.open_file ~cell_width:Cell_map.width path |> Or_error.ok_exn
  in
  Ui_state.create ~tiles_visible:false ~views:[ Vcs_view.entry ~cwd:repo.work () ] controller
;;

(* Keys, then every job the view submits, run to completion (printed by lane). *)
let run ?(quiet = false) repo t keys =
  let t = Helpers.run ~width ~height t (Helpers.keys keys) in
  let t, jobs = Vcs_driver.settle repo t ~width ~height in
  if (not quiet) && not (List.is_empty jobs)
  then
    printf "jobs: %s\n" (String.concat ~sep:", " (List.map jobs ~f:Vcs_driver.describe));
  t
;;

(* Keys only: jobs stay queued. *)
let keys t keys = Helpers.run ~width ~height t (Helpers.keys keys)

let scrub (repo : Fixture.t) text =
  String.substr_replace_all text ~pattern:repo.dir ~with_:"$DIR"
;;

let vcs t = Option.value_exn (View_registry.find (Ui_state.views t) Vcs_view.key)

let focus_name focus = Sexp.to_string [%sexp (focus : Vcs_view.Focus.t)]

(* Focus (the view's inner focus when it has it), the popup, the footer notice and the
   feedback line when it changed. *)
let where repo t =
  let focused = Ui_state.focused_view t ~width ~height in
  printf "focused %s" (View_id.to_string focused);
  if View_id.equal focused Vcs_view.id
  then printf " (%s)" (focus_name (Vcs_view.focus (vcs t)));
  Option.iter (Ui_state.popup t) ~f:(fun popup ->
    let state = Popup_tile.state popup in
    printf "; popup %s [%s]" (Popup_tile.title popup) (String.concat ~sep:" " state.enabled));
  print_endline "";
  Option.iter (Ui_state.capture_notice t) ~f:(fun notice ->
    printf "notice: %s\n" (scrub repo notice));
  Option.iter (Ui_state.message t) ~f:(fun message ->
    if not
         (String.equal message.text "VCS focused"
          || String.equal message.text !last_message)
    then (
      last_message := message.text;
      printf "message: %s\n" (scrub repo message.text)))
;;

let frame_lines t = String.split_lines (Frame.to_string (Frame.render t ~width ~height))

(* The text of [line] from display column [x], [width] columns. *)
let cut line ~x ~width =
  let column = ref 0 in
  Array.fold (Cell_map.glyphs line) ~init:"" ~f:(fun text (glyph : Cell_map.Glyph.t) ->
    let at = !column in
    column := at + glyph.width;
    if at >= x && at < x + width then text ^ glyph.text else text)
;;

let lists_width =
  (Option.value_exn
     (Vcs_view.Layout.compute ~width:(width - 4) ~rows:1 ~focus:Files ~log:false).lists)
    .width
;;

(* The Commits panel as drawn: its title row, then its rows up to the first blank. *)
let commits t =
  List.map (frame_lines t) ~f:(fun line -> String.rstrip (cut line ~x:2 ~width:lists_width))
  |> List.drop_while ~f:(fun row -> not (String.is_prefix row ~prefix:"3 Commits"))
  |> List.take_while ~f:(Fn.non String.is_empty)
  |> List.iter ~f:(fun row -> printf "| %s\n" row)
;;

(* The float's rows as drawn. *)
let popup_rows t =
  let lines = frame_lines t in
  Option.iter (Ui_state.popup_layout t ~width ~height) ~f:(fun (layout : Tile_shell.Layout.t) ->
    let outer = layout.outer in
    List.iter (List.take (List.drop lines outer.y) outer.height) ~f:(fun line ->
      print_endline (cut line ~x:outer.x ~width:outer.width)))
;;

(* The scope the view reads next, and the log commands of the command log since
   [after] (stale ones marked). *)
let scope t = print_s [%sexp (Vcs_view.scope (vcs t) : Ches_vcs.Log_scope.t)]

let log_commands ?(after = 0) repo t =
  List.drop (Vcs_view.log (vcs t)) after
  |> List.iter ~f:(fun (entry : Vcs_view.Log_entry.t) ->
    let command =
      String.chop_prefix_if_exists
        entry.command
        ~prefix:(String.concat ~sep:" " ("git" :: Ches_vcs_git.Cli.prefix) ^ " ")
    in
    if String.is_prefix command ~prefix:"--literal-pathspecs log "
    then
      printf
        "log: [%s%s] git %s\n"
        (Option.value entry.status ~default:"running")
        (if entry.stale then ", stale" else "")
        (scrub repo
           (String.substr_replace_all
              command
              ~pattern:
                " --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s --end-of-options"
              ~with_:" ...")))
;;

(* The diff text, numbered, the cursor's line marked with [>]. *)
let print_diff t =
  let view = Option.value_exn (Vcs_view.text_view (vcs t)) in
  let text = Text_view.text view in
  let cursor_line = String.count (String.prefix text (Text_view.cursor view)) ~f:(Char.equal '\n') in
  String.split_lines text
  |> List.iteri ~f:(fun i line ->
    printf "%s%2d|%s\n" (if i = cursor_line then ">" else " ") i line)
;;

(* The diff cursor's line. *)
let diff_line t =
  let view = Option.value_exn (Vcs_view.text_view (vcs t)) in
  let text = Text_view.text view in
  let cursor = Text_view.cursor view in
  let line = String.count (String.prefix text cursor) ~f:(Char.equal '\n') in
  printf
    "diff line %d: %s\n"
    line
    (Option.value (List.nth (String.split_lines text) line) ~default:"")
;;

let%expect_test "l opens the log popup with -g on; l l logs HEAD with the graph and refs" =
  with_history (fun repo ->
    let t = run repo (create repo) " gg" in
    commits t;
    let t = run repo t "l" in
    where repo t;
    popup_rows t;
    let t = run repo t "l" in
    where repo t;
    commits t;
    scope t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    | 3 Commits (6)
    | > - Recent commits (6)
    |   ● ae77634 (HEAD -> main) edit b
    |   ● fae2523 rename
    |   ●─╮ 46521dc Merge side
    |   │ ● e8808ae (side) side work
    |   ● │ 04217d0 (tag: v1) two
    |   ●─╯ fbcd33d one
    focused popup; popup Log [--graph]
    ╭─ Log ────────────────────────────────────────────────────────────────────╮
    │ Switches                                                                 │
    │ * -g  Show the graph (--graph)                                           │
    │   -m  Omit merges (--no-merges)                                          │
    │   -p  First parent only (--first-parent)                                 │
    │ Actions                                                                  │
    │   l  Log HEAD                                                            │
    │   b  Log a branch (select one in Branches first)                         │
    │   a  Log all branches                                                    │
    │   f  History of a file (select one first)                                │
    ╰──────────────────────────────────────────────────────────────────────────╯
    jobs: refresh g1.3
    focused vcs (Commits)
    | 3 Commits (6)
    | > - Recent commits (6)
    |   ● ae77634 (HEAD -> main) edit b
    |   ● fae2523 rename
    |   ●─╮ 46521dc Merge side
    |   │ ● e8808ae (side) side work
    |   ● │ 04217d0 (tag: v1) two
    |   ●─╯ fbcd33d one
    ((range Head) (path ()) (graph true) (merges true) (first_parent false)
     (limit 200))
    |}]
;;

let%expect_test "l b logs the branch selected in Branches; the title names it" =
  with_history (fun repo ->
    let t = run repo (create repo) " gg" in
    (* Without a selected branch, the action says so and refuses. *)
    let t = run repo t "l" in
    popup_rows t;
    let t = run repo t "b" in
    where repo t;
    let t = run repo t "2jjj" in
    let t = run repo t "l" in
    popup_rows t;
    let t = run repo t "b" in
    where repo t;
    commits t;
    (* The popup remembers the switches through the scope; l l returns to HEAD. *)
    let t = run repo t "l" in
    where repo t;
    let t = run repo t "l" in
    commits t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    ╭─ Log ────────────────────────────────────────────────────────────────────╮
    │ Switches                                                                 │
    │ * -g  Show the graph (--graph)                                           │
    │   -m  Omit merges (--no-merges)                                          │
    │   -p  First parent only (--first-parent)                                 │
    │ Actions                                                                  │
    │   l  Log HEAD                                                            │
    │   b  Log a branch (select one in Branches first)                         │
    │   a  Log all branches                                                    │
    │   f  History of a file (select one first)                                │
    ╰──────────────────────────────────────────────────────────────────────────╯
    focused vcs (Files)
    notice: Select a branch in Branches first
    ╭─ Log ────────────────────────────────────────────────────────────────────╮
    │ Switches                                                                 │
    │ * -g  Show the graph (--graph)                                           │
    │   -m  Omit merges (--no-merges)                                          │
    │   -p  First parent only (--first-parent)                                 │
    │ Actions                                                                  │
    │   l  Log HEAD                                                            │
    │   b  Log side                                                            │
    │   a  Log all branches                                                    │
    │   f  History of a file (select one first)                                │
    ╰──────────────────────────────────────────────────────────────────────────╯
    jobs: refresh g1.3
    focused vcs (Commits)
    | 3 Commits (2)
    | > - Commits on side (2)
    |   ● e8808ae (side) side work
    |   ● fbcd33d one
    focused popup; popup Log [--graph]
    jobs: refresh g1.4
    | 3 Commits (6)
    | > - Recent commits (6)
    |   ● ae77634 (HEAD -> main) edit b
    |   ● fae2523 rename
    |   ●─╮ 46521dc Merge side
    |   │ ● e8808ae (side) side work
    |   ● │ 04217d0 (tag: v1) two
    |   ●─╯ fbcd33d one
    |}]
;;

let%expect_test "l a logs all branches" =
  with_history (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "la" in
    where repo t;
    commits t;
    log_commands repo t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    jobs: refresh g1.3
    focused vcs (Commits)
    | 3 Commits (7)
    | > - All branches (7)
    |   ● ae77634 (HEAD -> main) edit b
    |   ● fae2523 rename
    |   ●─╮ 46521dc Merge side
    |   │ ● e8808ae (side) side work
    |   ● │ 04217d0 (tag: v1) two
    |   │ │ ● ef11f02 (other) other work
    |   ●─╯─╯ fbcd33d one
    log: [exit 0] git --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=200 --topo-order ... HEAD --
    log: [exit 0] git --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=200 --topo-order --branches --remotes ... HEAD --
    |}]
;;

let%expect_test "-m l hides the merge and drops the graph; -p l follows first parents" =
  with_history (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "l-ml" in
    where repo t;
    commits t;
    let t = run repo t "l" in
    where repo t;
    let t = run repo t "-m-pl" in
    commits t;
    scope t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    jobs: refresh g1.3
    focused vcs (Commits)
    | 3 Commits (5)
    | > - Recent commits (no merges) (5)
    |   ae77634 (HEAD -> main) edit b
    |   fae2523 rename
    |   04217d0 (tag: v1) two
    |   e8808ae (side) side work
    |   fbcd33d one
    focused popup; popup Log [--graph --no-merges]
    jobs: refresh g1.4
    | 3 Commits (5)
    | > - Recent commits (first parent) (5)
    |   ● ae77634 (HEAD -> main) edit b
    |   ● fae2523 rename
    |   ● 46521dc Merge side
    |   ● 04217d0 (tag: v1) two
    |   ● fbcd33d one
    ((range Head) (path ()) (graph true) (merges true) (first_parent true)
     (limit 200))
    |}]
;;

let%expect_test "+ doubles the commits read, up to the cap" =
  with_history (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "3j" in
    let before = List.length (Vcs_view.log (vcs t)) in
    let t = run repo t "+" in
    where repo t;
    log_commands ~after:before repo t;
    commits t;
    let t = run repo t "+++++" in
    let before = List.length (Vcs_view.log (vcs t)) in
    let t = run repo t "+" in
    where repo t;
    log_commands ~after:before repo t;
    scope t;
    (* Not in the other panels. *)
    let t = run repo t "1+" in
    where repo t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    jobs: diff g1.3
    jobs: refresh g1.4, diff g1.5
    focused vcs (Commits)
    log: [exit 0] git --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=400 --topo-order ... HEAD --
    | 3 Commits (6)
    |   - Recent commits (6)
    | > ● ae77634 (HEAD -> main) edit b
    |   ● fae2523 rename
    |   ●─╮ 46521dc Merge side
    |   │ ● e8808ae (side) side work
    |   ● │ 04217d0 (tag: v1) two
    |   ●─╯ fbcd33d one
    jobs: refresh g1.6, refresh g1.7, refresh g1.8, refresh g1.9, refresh g1.10, diff g1.11
    focused vcs (Commits)
    notice: Showing the most commits already (12800)
    ((range Head) (path ()) (graph true) (merges true) (first_parent false)
     (limit 12800))
    focused vcs (Files)
    notice: VCS: s/u/x stage/unstage/discard, c commit, m merge, l log, f/p/P fetch/pull/push, 1/2/3 panels, Tab diff, g r refresh, @ log, q leaves, ? help
    message: VCS: s/u/x stage/unstage/discard, c commit, m merge, l log, f/p/P fetch/pull/push, 1/2/3 panels, Tab diff, g r refresh, @ log, q leaves, ? help
    |}]
;;

let%expect_test "a scope chosen while a refresh is in flight: the stale read is dropped, the \
                 new one parsed with its own scope"
  =
  with_history (fun repo ->
    let t = run repo (create repo) " gg" in
    let before = List.length (Vcs_view.log (vcs t)) in
    let t = keys t "gr" in
    let t = keys t "la" in
    scope t;
    let t = run repo t "" in
    log_commands ~after:before repo t;
    commits t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    ((range All) (path ()) (graph true) (merges true) (first_parent false)
     (limit 200))
    jobs: refresh g1.3, refresh g1.4
    log: [exit 0, stale] git --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=200 --topo-order ... HEAD --
    log: [exit 0] git --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=200 --topo-order --branches --remotes ... HEAD --
    | 3 Commits (7)
    | > - All branches (7)
    |   ● ae77634 (HEAD -> main) edit b
    |   ● fae2523 rename
    |   ●─╮ 46521dc Merge side
    |   │ ● e8808ae (side) side work
    |   ● │ 04217d0 (tag: v1) two
    |   │ │ ● ef11f02 (other) other work
    |   ●─╯─╯ fbcd33d one
    |}]
;;

let%expect_test "l f from Files and from a commit's diff; Enter in the history lands on the \
                 file" =
  with_history (fun repo ->
    Fixture.write repo "z.txt" "z\nzz\nzzz\n";
    let t = run repo (create repo) " gg" in
    (* Files: the selected item. *)
    let t = run repo t "j" in
    let t = run repo t "l" in
    popup_rows t;
    let t = run repo t "f" in
    where repo t;
    commits t;
    (* The second commit, "two", changed a.txt then z.txt: its diff starts at z.txt. *)
    let t = run repo t "jj" in
    let t = run repo t "<CR>" in
    where repo t;
    diff_line t;
    (* Back to HEAD; in Commits, the file is the one at the diff's cursor. *)
    let t = run repo t "<Tab>ll" in
    let t = run repo t "jj" in
    let t = run repo t "lf" in
    where repo t;
    let t = run repo t "<Tab>}<Tab>" in
    let t = run repo t "l" in
    popup_rows t;
    let t = run repo t "f" in
    where repo t;
    commits t;
    (* Following the rename: "rename" lands on b.txt (a.txt's new path). *)
    let t = run repo t "jj<CR>" in
    diff_line t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2, diff g1.3
    jobs: diff g1.4
    ╭─ Log ────────────────────────────────────────────────────────────────────╮
    │ Switches                                                                 │
    │ * -g  Show the graph (--graph)                                           │
    │   -m  Omit merges (--no-merges)                                          │
    │   -p  First parent only (--first-parent)                                 │
    │ Actions                                                                  │
    │   l  Log HEAD                                                            │
    │   b  Log a branch (select one in Branches first)                         │
    │   a  Log all branches                                                    │
    │   f  History of z.txt                                                    │
    ╰──────────────────────────────────────────────────────────────────────────╯
    jobs: refresh g1.5
    focused vcs (Commits)
    | 3 Commits (2)
    | > - History of z.txt (2)
    |   04217d0 (tag: v1) two
    |   fbcd33d one
    jobs: diff g1.6, diff g1.7
    focused vcs (Diff)
    diff line 18: diff --git a/z.txt b/z.txt
    jobs: refresh g1.8
    jobs: diff g1.9, diff g1.10
    focused vcs (Commits)
    notice: Select a file first: a Files item, or a file in the diff
    ╭─ Log ────────────────────────────────────────────────────────────────────╮
    │ Switches                                                                 │
    │ * -g  Show the graph (--graph)                                           │
    │   -m  Omit merges (--no-merges)                                          │
    │   -p  First parent only (--first-parent)                                 │
    │ Actions                                                                  │
    │   l  Log HEAD                                                            │
    │   b  Log a branch (select one in Branches first)                         │
    │   a  Log all branches                                                    │
    │   f  History of b.txt                                                    │
    ╰──────────────────────────────────────────────────────────────────────────╯
    jobs: refresh g1.11
    focused vcs (Commits)
    | 3 Commits (4)
    | > - History of b.txt (4)
    |   ae77634 (HEAD -> main) edit b
    |   fae2523 rename
    |   04217d0 (tag: v1) two
    |   fbcd33d one
    jobs: diff g1.12, diff g1.13
    diff line 10: diff --git a/a.txt b/b.txt
    |}]
;;

let%expect_test "} and { move between files; Enter on a listed file jumps to it, e opens it" =
  with_history (fun repo ->
    let t = run repo (create repo) " gg" in
    (* "two": a.txt and z.txt. *)
    let t = run repo t "3jjjjj<CR>" in
    print_diff t;
    let t = run repo t "}" in
    diff_line t;
    let t = run repo t "}" in
    diff_line t;
    let t = run repo t "}" in
    where repo t;
    diff_line t;
    let t = run repo t "{" in
    diff_line t;
    let t = run repo t "{" in
    where repo t;
    diff_line t;
    let t = run repo t "2}" in
    diff_line t;
    let t = run repo t "gg2{" in
    where repo t;
    (* The second listed line. *)
    let t = run repo t "gg9j" in
    diff_line t;
    let t = run repo t "<CR>" in
    where repo t;
    diff_line t;
    (* e on a listed line opens the file. *)
    let t = run repo t "gg9je" in
    where repo t;
    printf
      "file %s\n"
      (Option.value_map
         (Ches_core.Editor.path (Controller.editor (Ui_state.controller t)))
         ~default:"none"
         ~f:Filename.basename));
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    jobs: diff g1.3, diff g1.4, diff g1.5, diff g1.6, diff g1.7
    > 0|commit 04217d0347a619f5e651e65bbee0565c09238a8d
      1|Author:     Ches Test <ches-test@example.invalid>
      2|AuthorDate: 2026-01-01T00:00:00+00:00
      3|Commit:     Ches Test <ches-test@example.invalid>
      4|CommitDate: 2026-01-01T00:00:00+00:00
      5|
      6|    two
      7|
      8|M a.txt  +1 -0
      9|M z.txt  +1 -0
     10|
     11|diff --git a/a.txt b/a.txt
     12|index d00491f..1191247 100644
     13|--- a/a.txt
     14|+++ b/a.txt
     15|@@ -1 +1,2 @@
     16| 1
     17|+2
     18|diff --git a/z.txt b/z.txt
     19|index b680253..1b4b06b 100644
     20|--- a/z.txt
     21|+++ b/z.txt
     22|@@ -1 +1,2 @@
     23| z
     24|+zz
    diff line 11: diff --git a/a.txt b/a.txt
    diff line 18: diff --git a/z.txt b/z.txt
    focused vcs (Diff)
    notice: No next file
    diff line 18: diff --git a/z.txt b/z.txt
    diff line 11: diff --git a/a.txt b/a.txt
    focused vcs (Diff)
    notice: No previous file
    diff line 11: diff --git a/a.txt b/a.txt
    diff line 18: diff --git a/z.txt b/z.txt
    focused vcs (Diff)
    notice: No previous file
    diff line 9: M z.txt  +1 -0
    focused vcs (Diff)
    diff line 18: diff --git a/z.txt b/z.txt
    focused document
    file z.txt
    |}]
;;

let%expect_test "Space g l with the view hidden and never shown: opens focused on the \
                 file's history" =
  with_history (fun repo ->
    let t = run repo (create repo) " gl" in
    where repo t;
    commits t;
    scope t;
    (* Hidden again, the scope is kept. *)
    let t = run repo t "q" in
    let t = run repo t " gg" in
    where repo t;
    commits t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    focused vcs (Commits)
    | 3 Commits (4)
    | > - History of b.txt (4)
    |   ae77634 (HEAD -> main) edit b
    |   fae2523 rename
    |   04217d0 (tag: v1) two
    |   fbcd33d one
    ((range Head) (path (b.txt)) (graph true) (merges true) (first_parent false)
     (limit 200))
    focused vcs (Commits)
    | 3 Commits (4)
    | > - History of b.txt (4)
    |   ae77634 (HEAD -> main) edit b
    |   fae2523 rename
    |   04217d0 (tag: v1) two
    |   fbcd33d one
    |}]
;;

let%expect_test "Space g l with the view in the split" =
  with_history (fun repo ->
    let t = run repo (create ~file:"z.txt" repo) " gs" in
    let t = run repo t "q" in
    where repo t;
    let t = run repo t " gl" in
    where repo t;
    scope t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    focused document
    message: VCS in split
    jobs: refresh g1.3
    focused vcs (Commits)
    ((range Head) (path (z.txt)) (graph true) (merges true) (first_parent false)
     (limit 200))
    |}]
;;

let%expect_test "Space g l from a directory buffer and for a file outside the repository" =
  with_history (fun repo ->
    let t =
      Ui_state.create
        ~tiles_visible:false
        ~views:[ Vcs_view.entry ~cwd:repo.work () ]
        (Ches_app.Startup.open_path ~cell_width:Cell_map.width repo.work |> Or_error.ok_exn)
    in
    last_message := "";
    let t = run repo t " gl" in
    where repo t;
    let outside = Fixture.plain_dir repo "elsewhere" ^/ "note.txt" in
    Out_channel.write_all outside ~data:"note\n";
    (* Never shown: the view opens, detects, and says why it did not apply. *)
    let t = run repo (create ~path:outside repo) " gl" in
    where repo t;
    commits t;
    scope t;
    (* Shown before: refused at once, nothing moves. *)
    let t = run repo t "q" in
    last_message := "";
    let t = run repo t " gl" in
    where repo t);
  [%expect {|
    focused document
    message: No file buffer here: Space g l shows the history of the file you are in
    jobs: detect g1.1, refresh g1.2
    focused vcs (Files)
    message: note.txt is not in the repository at $DIR/work
    | 3 Commits (6)
    | > - Recent commits (6)
    |   ● ae77634 (HEAD -> main) edit b
    |   ● fae2523 rename
    |   ●─╮ 46521dc Merge side
    |   │ ● e8808ae (side) side work
    |   ● │ 04217d0 (tag: v1) two
    |   ●─╯ fbcd33d one
    ((range Head) (path ()) (graph true) (merges true) (first_parent false)
     (limit 200))
    focused document
    message: note.txt is not in the repository at $DIR/work
    |}]
;;

(* The head summary: the lists column's rows above the Files panel. *)
let summary t =
  List.drop (frame_lines t) 2
  |> List.map ~f:(fun line -> String.rstrip (cut line ~x:2 ~width:lists_width))
  |> List.take_while ~f:(fun row -> not (String.is_prefix row ~prefix:"1 Files"))
  |> List.filter ~f:(Fn.non String.is_empty)
  |> List.iter ~f:(fun row -> printf "| %s\n" row)
;;

(* The Branches panel as drawn: its title row, then its rows up to the first blank. *)
let branches t =
  List.map (frame_lines t) ~f:(fun line -> String.rstrip (cut line ~x:2 ~width:lists_width))
  |> List.drop_while ~f:(fun row -> not (String.is_prefix row ~prefix:"2 Branches"))
  |> List.take_while ~f:(Fn.non String.is_empty)
  |> List.iter ~f:(fun row -> printf "| %s\n" row)
;;

(* Records the behaviour while the owner decides whether the title should name the
   log when it is empty (VCS_WORKSPACE_PLAN.md, phase 8's known gaps). *)
let%expect_test "an empty chosen log: the logged branch deleted outside the view, and an \
                 unborn branch"
  =
  with_history (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "2jj" in
    let t = run repo t "lb" in
    where repo t;
    commits t;
    git repo [ "branch"; "-D"; "-q"; "other" ];
    let t = run repo t "gr" in
    where repo t;
    summary t;
    commits t;
    scope t;
    log_commands repo t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    jobs: refresh g1.3
    focused vcs (Commits)
    | 3 Commits (2)
    | > - Commits on other (2)
    |   ● ef11f02 (other) other work
    |   ● fbcd33d one
    jobs: refresh g1.4
    focused vcs (Commits)
    | Head: main ae77634
    | 1 problem reading the repository (@: >
    | 3 Commits (0)
    |   (none)
    ((range (Branch other)) (path ()) (graph true) (merges true)
     (first_parent false) (limit 200))
    log: [exit 0] git --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=200 --topo-order ... HEAD --
    log: [exit 0] git --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=200 --topo-order ... refs/heads/other --
    log: [exit 128] git --literal-pathspecs log -z --no-color --no-show-signature --decorate=short --max-count=200 --topo-order ... refs/heads/other --
    |}];
  (* An unborn branch is not listed in Branches, so l b cannot choose it; HEAD's log
     on it (l l) is empty too. *)
  with_history (fun repo ->
    git repo [ "switch"; "-q"; "--orphan"; "fresh" ];
    let t = run repo (create repo) " gg" in
    summary t;
    branches t;
    let t = run repo t "ll" in
    where repo t;
    summary t;
    commits t;
    scope t);
  [%expect {|
    jobs: detect g1.1, refresh g1.2
    | Head: fresh (no commits yet)
    | 2 Branches (3)
    | > - Local branches (3)
    |     main  edit b
    |     other  other work
    |     side  side work
    jobs: refresh g1.3
    focused vcs (Commits)
    | Head: fresh (no commits yet)
    | 3 Commits (0)
    |   (none)
    ((range Head) (path ()) (graph true) (merges true) (first_parent false)
     (limit 200))
    |}]
;;
