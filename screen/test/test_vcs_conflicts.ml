(* The VCS view's merges, rebases and conflict resolution (phase 7) end to end: the
   default bindings ([m] and [r] anywhere, [x] on a conflicted file, the editor's
   [Space x u] on its markers), git's own plans, and git run synchronously by
   [Vcs_driver] in fixture repositories. A merge from [m m] stopping on three
   conflicts, resolved by taking theirs, by restoring the markers and then ours, and in
   the editor, then committed with [m m]; a rebase pull stopping, continued, stopping
   again and skipped; the refusals for unsaved buffers, a missing branch, no rebase and
   a fast-forward-only merge. Paths under the fixture print as $DIR; commit hashes are
   reproducible. *)

open! Core
open Ches_screen
module Controller = Ches_app.Controller
module Editor = Ches_core.Editor
module View_id = Ches_tile.View_id
module Local_command = Ches_tile.Local_command
module Fixture = Ches_vcs_fixture.Fixture_repo

let width = 120
let height = 30
let git ?cwd repo args = ignore (Fixture.git ?cwd repo args : string)

(* f, g and h conflict between main ("ours") and other ("theirs"); notes.txt, which
   the editor opens, does not. *)
let with_merge f =
  Fixture.with_repo (fun repo ->
    let write contents =
      List.iter [ "f"; "g"; "h" ] ~f:(fun path -> Fixture.write repo path contents)
    in
    Fixture.write repo "notes.txt" "notes\n";
    write "base\n";
    ignore (Fixture.commit_all repo "Base" : string);
    git repo [ "switch"; "-q"; "-c"; "other" ];
    write "theirs\n";
    ignore (Fixture.commit_all repo "Theirs" : string);
    git repo [ "switch"; "-q"; "main" ];
    write "ours\n";
    ignore (Fixture.commit_all repo "Ours" : string);
    f repo)
;;

(* The feedback line last printed by [where]: it shows only a new one. *)
let last_message = ref ""

let create (repo : Fixture.t) path =
  last_message := "";
  let controller =
    Controller.open_file ~cell_width:Cell_map.width (Fixture.path repo path)
    |> Or_error.ok_exn
  in
  Ui_state.create
    ~tiles_visible:false
    ~views:[ Vcs_view.entry ~cwd:repo.work () ]
    controller
;;

(* Keys, then every job the view submits, run to completion (printed by lane). *)
let run repo t keys =
  let t = Helpers.run ~width ~height t (Helpers.keys keys) in
  let t, jobs = Vcs_driver.settle repo t ~width ~height in
  if not (List.is_empty jobs)
  then
    printf "jobs: %s\n" (String.concat ~sep:", " (List.map jobs ~f:Vcs_driver.describe));
  t
;;

let scrub (repo : Fixture.t) text =
  String.substr_replace_all text ~pattern:repo.dir ~with_:"$DIR"
;;

let vcs t = Option.value_exn (View_registry.find (Ui_state.views t) Vcs_view.key)

(* Focus, the float, the footer notice and the feedback line when it changed. *)
let where repo t =
  printf "focused %s" (View_id.to_string (Ui_state.focused_view t ~width ~height));
  Option.iter (Ui_state.popup t) ~f:(fun popup ->
    printf "; popup %s" (Popup_tile.title popup));
  Option.iter (Ui_state.confirm t) ~f:(fun confirm ->
    printf "; confirm %s" (Confirm_tile.title confirm));
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

(* The float's rows as drawn. *)
let float_rows t =
  let lines = frame_lines t in
  Option.iter
    (List.find_map [ Ui_state.popup_layout; Ui_state.confirm_layout ] ~f:(fun layout ->
       layout t ~width ~height))
    ~f:(fun (layout : Tile_shell.Layout.t) ->
      let outer = layout.outer in
      List.iter
        (List.take (List.drop lines outer.y) outer.height)
        ~f:(fun line -> print_endline (cut line ~x:outer.x ~width:outer.width)))
;;

(* The head summary: the lists column's rows above the Files panel. *)
let summary t =
  let lists =
    Vcs_view.Layout.compute ~width:(width - 4) ~rows:1 ~focus:Files ~log:false
  in
  let columns = (Option.value_exn lists.lists).width in
  List.drop (frame_lines t) 2
  |> List.map ~f:(fun line -> String.rstrip (cut line ~x:2 ~width:columns))
  |> List.take_while ~f:(fun row -> not (String.is_prefix row ~prefix:"1 Files"))
  |> List.filter ~f:(Fn.non String.is_empty)
  |> List.iter ~f:(fun row -> printf "| %s\n" row)
;;

(* The command log's mutations since [after] entries, with status and output. *)
let commands ?(after = 0) repo t =
  List.drop (Vcs_view.log (vcs t)) after
  |> List.iter ~f:(fun (entry : Vcs_view.Log_entry.t) ->
    let command =
      String.chop_prefix_if_exists
        entry.command
        ~prefix:(String.concat ~sep:" " ("git" :: Ches_vcs_git.Cli.prefix) ^ " ")
    in
    if not
         (List.exists
            [ "status"; "for-each-ref"; "log"; "diff"; "rev-parse"; "-c" ]
            ~f:(fun prefix -> String.is_prefix command ~prefix))
    then (
      printf
        "log: [%s] git %s\n"
        (Option.value entry.status ~default:"running")
        (scrub repo command);
      List.iter entry.output ~f:(fun line -> printf "      %S\n" (scrub repo line))))
;;

let log_length t = List.length (Vcs_view.log (vcs t))

let status repo =
  printf
    "status: %s\n"
    (match String.split_lines (Fixture.git repo [ "status"; "--short" ]) with
     | [] -> "clean"
     | lines -> String.concat ~sep:", " lines)
;;

let file repo path = printf "%s: %S\n" path (In_channel.read_all (Fixture.path repo path))

(* Subjects of HEAD's history, newest first, the branch and the status. *)
let head repo =
  printf
    "HEAD: %s; branch %s\n"
    (Fixture.git repo [ "log"; "--format=%s"; "HEAD"; "--" ]
     |> String.split_lines
     |> String.concat ~sep:" < ")
    (String.strip (Fixture.git repo [ "branch"; "--show-current" ]));
  status repo
;;

(* The editor's file, cursor line, dirty flag and text. *)
let editor t =
  let editor = Controller.editor (Ui_state.controller t) in
  printf
    "editor: %s line %d%s %S\n"
    (Option.value_map (Editor.path editor) ~default:"none" ~f:Filename.basename)
    (Editor.cursor_line editor + 1)
    (if Editor.is_dirty editor then " (dirty)" else "")
    (Ches_core.Text_buffer.to_string (Editor.text editor))
;;

let names t =
  List.map (Vcs_view.commands (vcs t)) ~f:(fun (command : Local_command.t) ->
    command.name)
  |> String.concat ~sep:" "
;;

let describe t name =
  List.iter (Vcs_view.commands (vcs t)) ~f:(fun (command : Local_command.t) ->
    if String.equal command.name name
    then printf "%s: %s\n" command.name command.description)
;;

let selected t =
  let v = vcs t in
  print_s
    [%sexp
      ((Vcs_view.cursor v (Vcs_view.list_focus v)).selected
       : Ches_vcs.Panel.Position.t option)]
;;

let%expect_test "a merge from m m stops on conflicts; x takes theirs, restores markers; \
                 Space x u in the editor; s; m m commits"
  =
  with_merge (fun repo ->
    let t = run repo (create repo "notes.txt") " gg" in
    (* m merges the branch selected in Branches, whatever has focus: other. *)
    let t = run repo t "2jj1" in
    let t = run repo t "m" in
    where repo t;
    float_rows t;
    let t = run repo t "m" in
    where repo t;
    summary t;
    commands repo t;
    status repo;
    print_endline (names t);
    [%expect {|
      jobs: detect g1.1, refresh g1.2
      focused popup; popup Merge
      ╭─ Merge ──────────────────────────────────────╮
      │ Switches                                     │
      │   -n  Always create a merge commit (--no-ff) │
      │   -f  Fast-forward only (--ff-only)          │
      │ Actions                                      │
      │   m  Merge other                             │
      ╰──────────────────────────────────────────────╯
      jobs: - g1.3, refresh g1.4, diff g1.5
      focused vcs
      message: Merge other failed: Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it resolved with s, then continue
      | Head: main b986162
      | Merging 93dff37 (press m)
      log: [exit 1] git merge --no-edit --end-of-options other
      status: UU f, UU g, UU h
      refresh toggle-log leave focus-files focus-branches focus-commits focus-diff toggle-diff toggle-fold stage unstage discard stage-all unstage-all commit fetch pull push merge copy next previous first last half-page-down half-page-up
      |}];
    (* The section header: the backend's refusal. *)
    let t = run repo t "ggx" in
    where repo t;
    (* f: x on its row, t takes theirs, confirmed; f leaves Conflicted. *)
    let t = run repo t "j" in
    selected t;
    describe t "discard";
    let t = run repo t "x" in
    where repo t;
    float_rows t;
    let t = run repo t "t" in
    where repo t;
    float_rows t;
    let after = log_length t in
    let t = run repo t "y" in
    where repo t;
    commands ~after repo t;
    selected t;
    status repo;
    file repo "f";
    [%expect {|
      focused vcs
      notice: Resolve conflicted files one at a time (x on a file); nothing ran
      jobs: diff g1.6
      ((Item (section conflicted) (key f)))
      discard: Resolve the conflicted file (take a side)
      focused popup; popup Resolve f
      ╭─ Resolve f ──────────────────────────────────────────────────────────────╮
      │ Actions                                                                  │
      │   o  Take ours (HEAD)                 m  Restore the conflict markers    │
      │   t  Take theirs (93dff37)                                               │
      ╰──────────────────────────────────────────────────────────────────────────╯
      focused confirm; confirm Resolve f
      ╭─ Resolve f ──────────────────────────────────────────────────╮
      │ Take theirs (93dff37) for f? The other side's changes and    │
      │ any edits to the file are lost; it is marked resolved.       │
      │ y yes   n no (default)                                       │
      ╰──────────────────────────────────────────────────────────────╯
      jobs: - g1.7, refresh g1.8, diff g1.9
      focused vcs
      log: [exit 0] git --literal-pathspecs checkout --theirs -- f
      log: [exit 0] git --literal-pathspecs add --all -- f
      ((Item (section conflicted) (key g)))
      status: M  f, UU g, UU h
      f: "theirs\n"
      |}];
    (* g: a bad edit, then x m restores the markers; it stays conflicted. Then x o
       takes ours. *)
    Fixture.write repo "g" "oops\n";
    let t = run repo t "gr" in
    selected t;
    let t = run repo t "xm" in
    where repo t;
    float_rows t;
    let t = run repo t "y" in
    where repo t;
    status repo;
    file repo "g";
    let t = run repo t "xoy" in
    where repo t;
    status repo;
    file repo "g";
    [%expect {|
      jobs: refresh g1.10, diff g1.11
      ((Item (section conflicted) (key g)))
      focused confirm; confirm Resolve g
      ╭─ Resolve g ──────────────────────────────────────────────────╮
      │ Restore the conflict markers in g? Edits to the file are     │
      │ lost.                                                        │
      │ y yes   n no (default)                                       │
      ╰──────────────────────────────────────────────────────────────╯
      jobs: - g1.12, refresh g1.13, diff g1.14
      focused vcs
      status: M  f, UU g, UU h
      g: "<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n"
      jobs: - g1.15, refresh g1.16, diff g1.17
      focused vcs
      status: M  f, UU h
      g: "ours\n"
      |}];
    (* h: Enter focuses its diff; x on the file's header opens the popup (Escape
       declines it), x on a hunk is refused; ] then Enter opens the file at the
       conflict. *)
    selected t;
    let t = run repo t "<CR>" in
    describe t "discard";
    let t = run repo t "x" in
    where repo t;
    let t = run repo t "<Esc>]x" in
    where repo t;
    let t = run repo t "<CR>" in
    where repo t;
    editor t;
    [%expect {|
      ((Item (section conflicted) (key h)))
      discard: Resolve the conflicted file (take a side)
      focused popup; popup Resolve h
      focused vcs
      notice: Resolve conflicts in the editor: Enter opens the file at the conflict, Space x u, l, a or b keeps a side; nothing ran
      focused document
      editor: h line 1 "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n"
      |}];
    (* Space x u keeps the upper side (ours); m m is refused while h is conflicted;
       Space w saves, and s marks it resolved. *)
    let t = run repo t " xu" in
    where repo t;
    editor t;
    let t = run repo t " w" in
    where repo t;
    editor t;
    let t = run repo t " gg" in
    let t = run repo t "mm" in
    where repo t;
    let t = run repo t "<Tab>s" in
    where repo t;
    status repo;
    [%expect {|
      focused document
      message: Kept upper (HEAD)
      editor: h line 1 (dirty) "ours\n"
      jobs: refresh g1.18, diff g1.19
      focused document
      message: Wrote $DIR/work/h (5 bytes)
      editor: h line 1 "ours\n"
      focused vcs
      notice: Resolve the conflicted files first (s marks one resolved); nothing ran
      jobs: - g1.20, refresh g1.21, diff g1.22
      focused vcs
      status: M  f
      |}];
    (* An unsaved edit refuses m m; undone and saved, m m commits the merge: two
       parents, git's message without its "# Conflicts" comment. *)
    let t = run repo t "q" in
    let t = run repo t "ox<Esc>" in
    editor t;
    let t = run repo t " gg" in
    let t = run repo t "mm" in
    where repo t;
    status repo;
    let t = run repo t "qu w" in
    editor t;
    let t = run repo t " gg" in
    let t = run repo t "mm" in
    where repo t;
    summary t;
    head repo;
    printf
      "parents: %s\n"
      (Fixture.git repo [ "log"; "-1"; "--format=%p" ] |> String.strip);
    print_endline "message:";
    List.iter
      (String.split_lines
         (String.rstrip (Fixture.git repo [ "log"; "-1"; "--format=%B" ])))
      ~f:(printf "| %s\n");
    print_endline (names t);
    [%expect {|
      editor: h line 2 (dirty) "ours\nx\n"
      focused vcs
      notice: Commit merge refused: unsaved changes in h; save or undo them first; nothing ran
      message: Commit merge refused: unsaved changes in h; save or undo them first; nothing ran
      status: M  f
      jobs: refresh g1.23, diff g1.24
      editor: h line 1 "ours\n"
      jobs: - g1.25, refresh g1.26
      focused vcs
      | Head: main e155531
      HEAD: Merge branch 'other' < Ours < Theirs < Base; branch main
      status: clean
      parents: b986162 93dff37
      message:
      | Merge branch 'other'
      refresh toggle-log leave focus-files focus-branches focus-commits focus-diff toggle-diff stage unstage discard stage-all unstage-all commit fetch pull push merge copy next previous first last half-page-down half-page-up
      |}])
;;

(* main has two commits on [a.txt] that conflict with the upstream's. *)
let with_diverged_rebase f =
  Fixture.with_repo ~remote:true (fun repo ->
    Fixture.write repo "a.txt" "one\n";
    ignore (Fixture.commit_all repo "One" : string);
    git repo [ "push"; "-q"; "-u"; "origin"; "main" ];
    let other = Fixture.plain_dir repo "other" in
    git ~cwd:repo.dir repo [ "clone"; "-q"; Option.value_exn repo.remote; other ];
    Out_channel.write_all (Filename.concat other "a.txt") ~data:"theirs\n";
    git ~cwd:other repo [ "commit"; "-q"; "-am"; "Theirs" ];
    git ~cwd:other repo [ "push"; "-q" ];
    Fixture.write repo "a.txt" "ours one\n";
    ignore (Fixture.commit_all repo "Ours one" : string);
    Fixture.write repo "a.txt" "ours two\n";
    ignore (Fixture.commit_all repo "Ours two" : string);
    f repo)
;;

let%expect_test "a rebase pull stops; r r with an unsaved buffer is refused; r r stops \
                 again; r s asks, y skips"
  =
  with_diverged_rebase (fun repo ->
    let t = run repo (create repo "a.txt") " gg" in
    let t = run repo t "p-rp" in
    where repo t;
    summary t;
    print_endline (names t);
    describe t "rebase";
    let t = run repo t "r" in
    where repo t;
    float_rows t;
    [%expect {|
      jobs: detect g1.1, refresh g1.2
      jobs: - g1.3, refresh g1.4, diff g1.5
      focused vcs
      message: Pull from origin/main (rebase) failed: Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it resolved with s, then continue
      | Head: detached at 143c3f4
      | Rebasing main onto 143c3f4 (press r)
      refresh toggle-log leave focus-files focus-branches focus-commits focus-diff toggle-diff toggle-fold stage unstage discard stage-all unstage-all commit fetch pull push rebase merge copy next previous first last half-page-down half-page-up
      rebase: Continue, skip or abort the rebase (the rebase popup)
      focused popup; popup Rebasing
      ╭─ Rebasing ─────────────────────────────────────────╮
      │ Actions                                            │
      │   r  Continue             a  Abort                 │
      │   s  Skip this commit                              │
      ╰────────────────────────────────────────────────────╯
      |}];
    (* x on a.txt names the sides for a rebase; o takes the upstream's, which empties
       the commit being applied. *)
    let t = run repo t "<Esc>1ggj" in
    selected t;
    let t = run repo t "x" in
    float_rows t;
    let t = run repo t "oy" in
    where repo t;
    status repo;
    editor t;
    [%expect {|
      ((Item (section conflicted) (key a.txt)))
      ╭─ Resolve a.txt ──────────────────────────────────────────────────────────╮
      │ Actions                                                                  │
      │   o  Take ours (the upstream)         m  Restore the conflict markers    │
      │   t  Take theirs (your commit)                                           │
      ╰──────────────────────────────────────────────────────────────────────────╯
      jobs: - g1.6, refresh g1.7
      focused vcs
      message: Reloaded from disk: a.txt
      status: clean
      editor: a.txt line 1 "theirs\n"
      |}];
    (* An unsaved edit of a.txt refuses r r. *)
    let t = run repo t "q" in
    let t = run repo t "ox<Esc>" in
    let t = run repo t " gg" in
    let t = run repo t "rr" in
    where repo t;
    let t = run repo t "qu w" in
    editor t;
    (* r r: the emptied commit is dropped, the next one stops again. *)
    let t = run repo t " gg" in
    let t = run repo t "rr" in
    where repo t;
    summary t;
    status repo;
    [%expect {|
      focused vcs
      notice: Continue rebase refused: unsaved changes in a.txt; save or undo them first; nothing ran
      message: Continue rebase refused: unsaved changes in a.txt; save or undo them first; nothing ran
      jobs: refresh g1.8
      editor: a.txt line 1 "theirs\n"
      jobs: - g1.9, refresh g1.10, diff g1.11
      focused vcs
      message: Continue rebase failed: Stopped on conflicts: resolve each file (x, or Space x in the editor), mark it resolved with s, then continue
      | Head: detached at 143c3f4
      | Rebasing main onto 143c3f4 (press r)
      status: UU a.txt
      |}];
    let t = run repo t "rs" in
    where repo t;
    float_rows t;
    let t = run repo t "y" in
    where repo t;
    summary t;
    head repo;
    print_endline (names t);
    [%expect {|
      focused confirm; confirm Skip commit
      ╭─ Skip commit ────────────────────────────────────────────────╮
      │ Skip the commit being applied? Its changes are left out of   │
      │ the rebased branch.                                          │
      │ y yes   n no (default)                                       │
      ╰──────────────────────────────────────────────────────────────╯
      jobs: - g1.12, refresh g1.13
      focused vcs
      message: Reloaded from disk: a.txt
      | Head: main 143c3f4
      | Upstream: origin/main, up to date
      HEAD: Theirs < One; branch main
      status: clean
      refresh toggle-log leave focus-files focus-branches focus-commits focus-diff toggle-diff stage unstage discard stage-all unstage-all commit fetch pull push merge copy next previous first last half-page-down half-page-up
      |}])
;;

let%expect_test "m with no branch selected; m on the current branch; a refused \
                 fast-forward-only merge; r with no rebase"
  =
  with_merge (fun repo ->
    let t = run repo (create repo "notes.txt") " gg" in
    print_endline (names t);
    describe t "merge";
    let t = run repo t "m" in
    where repo t;
    float_rows t;
    let t = run repo t "m" in
    where repo t;
    (* The current branch: the backend's refusal. *)
    let t = run repo t "2j" in
    let t = run repo t "mm" in
    where repo t;
    (* -f: git refuses to fast-forward diverged branches; its own line, no pull
       advice. *)
    let t = run repo t "j" in
    let t = run repo t "m-fm" in
    where repo t;
    head repo;
    let t = run repo t "r" in
    where repo t;
    [%expect {|
      jobs: detect g1.1, refresh g1.2
      refresh toggle-log leave focus-files focus-branches focus-commits focus-diff toggle-diff stage unstage discard stage-all unstage-all commit fetch pull push merge copy next previous first last half-page-down half-page-up
      merge: Merge the branch selected in Branches (the merge popup)
      focused popup; popup Merge
      ╭─ Merge ────────────────────────────────────────╮
      │ Switches                                       │
      │   -n  Always create a merge commit (--no-ff)   │
      │   -f  Fast-forward only (--ff-only)            │
      │ Actions                                        │
      │   m  Merge (select a branch in Branches first) │
      ╰────────────────────────────────────────────────╯
      focused vcs
      notice: Select the branch to merge in Branches (2) first; nothing ran
      focused vcs
      notice: Cannot merge main into itself; nothing ran
      jobs: - g1.3, refresh g1.4
      focused vcs
      message: Merge other (fast-forward only) failed: fatal: Not possible to fast-forward, aborting. (exit 128)
      HEAD: Ours < Base; branch main
      status: clean
      focused vcs
      notice: No rebase in progress; nothing ran
      |}])
;;
