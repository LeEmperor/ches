(* The VCS view's commit flow (phase 5) end to end: the default bindings ([c] in the
   view, [Space g c] and [Space g a] in the message buffer), git's own commit plans,
   and git run synchronously by [Vcs_driver] in a fixture repository. The commit
   popup, the message buffer as a file tab, finishing, aborting, refusals, hooks,
   amend and extend, and what happens to the message file. Paths under the fixture
   print as $DIR; commit hashes are reproducible. *)

open! Core
open Ches_screen
module Controller = Ches_app.Controller
module Editor = Ches_core.Editor
module View_id = Ches_tile.View_id
module Fixture = Ches_vcs_fixture.Fixture_repo
module B = Ches_vcs_git.Backend

let width = 100
let height = 24

(* Two committed files, [a.txt] changed and staged since. The editor opens [a.txt],
   with the default bindings. *)
let with_repo ?(stage = true) f =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "a.txt" "one\ntwo\n";
    Fixture.write repo "b.txt" "bee\n";
    ignore (Fixture.commit_all repo "first" : string);
    Fixture.write repo "a.txt" "one\nTWO\n";
    if stage then ignore (Fixture.git repo [ "add"; "a.txt" ] : string);
    f repo)
;;

let create ?plan (repo : Fixture.t) =
  let controller =
    Controller.open_file ~cell_width:Cell_map.width (Fixture.path repo "a.txt")
    |> Or_error.ok_exn
  in
  Ui_state.create
    ~tiles_visible:false
    ~views:[ Vcs_view.entry ?plan ~cwd:repo.work () ]
    controller
;;

(* Keys, then every job the view submits, run to completion (printed by lane). *)
let run ?(quiet = false) repo t keys =
  let t = Helpers.run ~width ~height t (Helpers.keys keys) in
  let t, jobs = Vcs_driver.settle repo t ~width ~height in
  if (not quiet) && not (List.is_empty jobs)
  then printf "jobs: %s\n" (String.concat ~sep:", " (List.map jobs ~f:Vcs_driver.describe));
  t
;;

let scrub (repo : Fixture.t) text =
  String.substr_replace_all text ~pattern:repo.dir ~with_:"$DIR"
;;

let vcs t = Option.value_exn (View_registry.find (Ui_state.views t) Vcs_view.key)
let message_file (repo : Fixture.t) = repo.work ^/ ".git/CHES_COMMIT_EDITMSG"

(* Focus, the tab strip (the active entry starred), the editor's buffer, the popup,
   the footer notice and the feedback line. *)
let where repo t =
  let editor = Controller.editor (Ui_state.controller t) in
  printf
    "focused %s; tabs [%s]; file %s line %d%s\n"
    (View_id.to_string (Ui_state.focused_view t ~width ~height))
    (String.concat
       ~sep:" "
       (List.map (Ui_state.tab_items t) ~f:(fun (item : Tab_strip.Item.t) ->
          (if item.active then "*" else "") ^ item.label)))
    (Option.value_map (Editor.path editor) ~default:"none" ~f:Filename.basename)
    (Editor.cursor_line editor + 1)
    (if Editor.is_dirty editor then " dirty" else "");
  Option.iter (Ui_state.popup t) ~f:(fun popup ->
    let state = Popup_tile.state popup in
    printf
      "popup %s [%s]%s\n"
      (Popup_tile.title popup)
      (String.concat ~sep:" " state.enabled)
      (if state.dash then " dash" else ""));
  Option.iter (Ui_state.capture_notice t) ~f:(fun notice ->
    printf "notice: %s\n" (scrub repo notice));
  Option.iter (Ui_state.message t) ~f:(fun message ->
    if not (String.equal message.text "VCS focused")
    then printf "message: %s\n" (scrub repo message.text))
;;

(* The editor's buffer, line by line. *)
let buffer repo t =
  let editor = Controller.editor (Ui_state.controller t) in
  printf
    "--- %s\n%s"
    (Option.value_map (Editor.path editor) ~default:"none" ~f:(scrub repo))
    (Ches_core.Text_buffer.to_string (Editor.text editor))
;;

(* HEAD's message, git's short status, and whether the message file is there. *)
let head (repo : Fixture.t) =
  printf
    "HEAD: %S\nlog: %s\nstatus: %s\nmessage file: %b\n"
    (Fixture.git repo [ "log"; "-1"; "--format=%B" ])
    (String.concat
       ~sep:" | "
       (String.split_lines (Fixture.git repo [ "log"; "--format=%h %s" ])))
    (String.concat ~sep:", " (String.split_lines (Fixture.git repo [ "status"; "--short" ])))
    (Sys_unix.file_exists_exn (message_file repo))
;;

(* The command log's commit commands (and the preparation's), with status and the
   stderr tail, since [after] entries. *)
let commands ?(after = 0) repo t =
  List.drop (Vcs_view.log (vcs t)) after
  |> List.iter ~f:(fun (entry : Vcs_view.Log_entry.t) ->
    let command =
      String.chop_prefix_if_exists
        entry.command
        ~prefix:(String.concat ~sep:" " ("git" :: Ches_vcs_git.Cli.prefix) ^ " ")
    in
    if List.exists [ "-c"; "commit"; "rev-parse --git-path"; "log -1" ] ~f:(fun prefix ->
         String.is_prefix command ~prefix)
    then (
      printf
        "log: [%s] git %s\n"
        (Option.value entry.status ~default:"running")
        (scrub repo command);
      List.iter entry.output ~f:(fun line -> printf "      %s\n" (scrub repo line))))
;;

(* The frame (rows naming the fixture squeezed as test_vcs_workspace does). *)
let show repo t =
  Frame.to_string (Frame.render t ~width ~height)
  |> String.split_lines
  |> List.iter ~f:(fun line ->
    if String.is_substring line ~substring:repo.Fixture.dir
    then
      print_endline
        (scrub repo line
         |> String.split ~on:' '
         |> List.filter ~f:(Fn.non String.is_empty)
         |> String.concat ~sep:" ")
    else print_endline line)
;;

(* The float's rows as drawn, and the cursor line. *)
let popup_rows t =
  let lines = String.split_lines (Frame.to_string (Frame.render t ~width ~height)) in
  let cut line ~x ~width =
    let column = ref 0 in
    Array.fold (Cell_map.glyphs line) ~init:"" ~f:(fun text (glyph : Cell_map.Glyph.t) ->
      let at = !column in
      column := at + glyph.width;
      if at >= x && at < x + width then text ^ glyph.text else text)
  in
  Option.iter
    (Option.first_some
       (Ui_state.help_layout t ~width ~height)
       (Ui_state.popup_layout t ~width ~height))
    ~f:(fun (layout : Tile_shell.Layout.t) ->
      let outer = layout.outer in
      List.iter (List.take (List.drop lines outer.y) outer.height) ~f:(fun line ->
        print_endline (cut line ~x:outer.x ~width:outer.width)))
;;

let%expect_test "c opens the commit popup over the view; - s toggles a switch; q declines" =
  with_repo (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "c" in
    where repo t;
    popup_rows t;
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2, diff g1.3
      focused popup; tabs [a.txt *VCS: main]; file a.txt line 1
      popup Commit []
      ╭─ Commit ────────────────────────────────────╮
      │ Switches                                    │
      │   -n  Disable hooks (--no-verify)           │
      │   -s  Add Signed-off-by line (--signoff)    │
      │   -e  Allow an empty commit (--allow-empty) │
      │ Actions                                     │
      │   c  Commit     a  Amend      e  Extend     │
      ╰─────────────────────────────────────────────╯
      |}];
    let t = run repo t "-s" in
    where repo t;
    popup_rows t;
    let t = run repo t "-s" in
    where repo t;
    let t = run repo t "q" in
    where repo t;
    head repo;
    [%expect
      {|
      focused popup; tabs [a.txt *VCS: main]; file a.txt line 1
      popup Commit [--signoff]
      ╭─ Commit ────────────────────────────────────╮
      │ Switches                                    │
      │   -n  Disable hooks (--no-verify)           │
      │ * -s  Add Signed-off-by line (--signoff)    │
      │   -e  Allow an empty commit (--allow-empty) │
      │ Actions                                     │
      │   c  Commit     a  Amend      e  Extend     │
      ╰─────────────────────────────────────────────╯
      focused popup; tabs [a.txt *VCS: main]; file a.txt line 1
      popup Commit []
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      HEAD: "first\n\n"
      log: 42c8e24 first
      status: M  a.txt
      message file: false
      |}];
    (* From the Branches panel and the diff too, not in Visual. *)
    let t = run repo t "2c" in
    where repo t;
    let t = run repo t "q1<Tab>c" in
    where repo t;
    let t = run repo t "qvc" in
    where repo t;
    (* [?] over the popup lists its keys. *)
    let t = run repo t "<Esc>c?" in
    popup_rows t;
    [%expect {|
      focused popup; tabs [a.txt *VCS: main]; file a.txt line 1
      popup Commit []
      jobs: diff g1.4
      focused popup; tabs [a.txt *VCS: main]; file a.txt line 1
      popup Commit []
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      notice: VCS: read-only; edits unavailable
      message: VCS: read-only; edits unavailable
      ╭─ Commit keys ─────────────────────────────╮
      │ -n  Disable hooks (--no-verify)           │
      │ -s  Add Signed-off-by line (--signoff)    │
      │ -e  Allow an empty commit (--allow-empty) │
      │ c   Commit                                │
      │ a   Amend                                 │
      │ e   Extend                                │
      ╰─ 0 above, 0 below ────────────────────────╯
      |}])
;;

let%expect_test "c c opens the message buffer; Space g c commits it, closes it, and returns \
                 to the refreshed view"
  =
  with_repo (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "c-sc" in
    where repo t;
    buffer repo t;
    commands repo t;
    [%expect {|
      jobs: detect g1.1, refresh g1.2, diff g1.3
      jobs: commit g1.4
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      --- $DIR/work/.git/CHES_COMMIT_EDITMSG

      # Write the commit message above. Lines starting with '#' are removed.
      # Space g c commits; Space g a aborts.
      #
      # On branch main
      # Switches: --signoff
      #
      # Changes to be committed:
      #	modified:   a.txt
      log: [exit 0] git rev-parse --git-path CHES_COMMIT_EDITMSG
      |}];
    let t = run repo t "iAdd TWO<Esc>" in
    let t = run repo t " gc" in
    where repo t;
    head repo;
    commands repo t;
    show repo t;
    [%expect {|
      jobs: - g1.5, refresh g1.6
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      message: [main a0515a6] Add TWO
      HEAD: "Add TWO\n\nSigned-off-by: Ches Test <ches-test@example.invalid>\n\n"
      log: a0515a6 Add TWO | 42c8e24 first
      status:
      message file: false
      log: [exit 0] git rev-parse --git-path CHES_COMMIT_EDITMSG
      log: [exit 0] git -c 'core.commentChar=#' commit --cleanup=strip --signoff -F $DIR/work/.git/CHES_COMMIT_EDITMSG
       1:a.txt [2:VCS: main]                                                                              |
      ╭─ VCS: work (main) ───────────────────────────────────────────────────────────────────────────────╮|
      │ Head: main a0515a6                    │ 0 Diff                                                   │|
      │                                       │                                                          │|
      │ 1 Files (0)                           │                                                          │|
      │   (none)                              │                                                          │|
      │                                       │                                                          │|
      │                                       │                                                          │|
      │                                       │                                                          │|
      │                                       │                                                          │|
      │                                       │                                                          │|
      │                                       │                                                          │|
      │                                       │                                                          │|
      │ 2 Branches (1)                        │                                                          │|
      │ > - Local branches (1)                │                                                          │|
      │   * main  Add TWO                     │                                                          │|
      │                                       │                                                          │|
      │ 3 Commits (2)                         │                                                          │|
      │ > - Recent commits (2)                │                                                          │|
      │   a0515a6 Add TWO                     │                                                          │|
      │   42c8e24 first                       │                                                          │|
      │                                       │                                                          │|
      ╰─ Files 0/0 ──────────────────────────────────────────────────────────────────────────────────────╯|
       NORMAL  VCS: main [main a0515a6] Add TWO                                                           |
      cursor: none
      |}])
;;

let%expect_test "from a split view: the message opens in the other pane; committing returns \
                 to the split; hidden, the editor stays"
  =
  with_repo (fun repo ->
    Fixture.write repo "b.txt" "BEE\n";
    let t = run ~quiet:true repo (create repo) " gs" in
    where repo t;
    let t = run repo t "cc" in
    where repo t;
    let t = run repo t "iSplit commit<Esc> gc" in
    where repo t;
    head repo;
    (* Hidden while the message is written: committing leaves the editor where it is. *)
    let t = run repo t "s" in
    let t = run repo t "cc" in
    let t = run repo t " ghiHidden<Esc> gc" in
    where repo t;
    head repo;
    [%expect {|
      focused vcs; tabs [*a.txt]; file a.txt line 1
      notice: VCS in split
      message: VCS in split
      jobs: commit g1.4
      focused document; tabs [a.txt *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: VCS in split
      jobs: - g1.5, refresh g1.6, diff g1.7
      focused vcs; tabs [*a.txt]; file a.txt line 1
      message: [main c1d98eb] Split commit
      HEAD: "Split commit\n\n"
      log: c1d98eb Split commit | 42c8e24 first
      status:  M b.txt
      message file: false
      jobs: - g1.8, refresh g1.9, diff g1.10
      jobs: commit g1.11
      jobs: - g1.12, refresh g1.13
      focused document; tabs [*a.txt]; file a.txt line 1
      message: [main b349f40] Hidden
      HEAD: "Hidden\n\n"
      log: b349f40 Hidden | c1d98eb Split commit | 42c8e24 first
      status:
      message file: false
      |}])
;;

let%expect_test "nothing staged refuses commit and extend; -e allows an empty commit" =
  with_repo ~stage:false (fun repo ->
    let t = run ~quiet:true repo (create repo) " gg" in
    let t = run repo t "cc" in
    where repo t;
    let t = run repo t "ce" in
    where repo t;
    let t = run repo t "c-ec" in
    where repo t;
    buffer repo t;
    let t = run repo t "iEmpty<Esc> gc" in
    where repo t;
    head repo;
    commands repo t;
    [%expect {|
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      notice: Nothing staged; stage changes first (s), or allow an empty commit (-e); nothing ran
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      notice: Nothing staged; stage changes first (s), or allow an empty commit (-e); nothing ran
      jobs: commit g1.4
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      --- $DIR/work/.git/CHES_COMMIT_EDITMSG

      # Write the commit message above. Lines starting with '#' are removed.
      # Space g c commits; Space g a aborts.
      #
      # On branch main
      # Switches: --allow-empty
      #
      # Changes to be committed:
      #	(nothing staged)
      jobs: - g1.5, refresh g1.6, diff g1.7
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      message: [main f6ee1d5] Empty
      HEAD: "Empty\n\n"
      log: f6ee1d5 Empty | 42c8e24 first
      status:  M a.txt
      message file: false
      log: [exit 0] git rev-parse --git-path CHES_COMMIT_EDITMSG
      log: [exit 0] git -c 'core.commentChar=#' commit --cleanup=strip --allow-empty -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      |}])
;;

let%expect_test "an empty message fails: the buffer stays open with git's reason" =
  with_repo (fun repo ->
    let t = run ~quiet:true repo (create repo) " gg" in
    let t = run repo t "cc" in
    let t = run repo t " gc" in
    where repo t;
    head repo;
    commands repo t;
    [%expect {|
      jobs: commit g1.4
      jobs: - g1.5, refresh g1.6, diff g1.7
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: Commit failed: Aborting commit due to empty commit message. (exit 1)
      HEAD: "first\n\n"
      log: 42c8e24 first
      status: M  a.txt
      message file: true
      log: [exit 0] git rev-parse --git-path CHES_COMMIT_EDITMSG
      log: [exit 1] git -c 'core.commentChar=#' commit --cleanup=strip -F $DIR/work/.git/CHES_COMMIT_EDITMSG
            Aborting commit due to empty commit message.
      |}])
;;

let%expect_test "c a amends with HEAD's message pre-filled; with nothing staged it rewords" =
  with_repo ~stage:false (fun repo ->
    ignore
      (Fixture.git
         repo
         [ "commit"; "--amend"; "-q"; "-m"; "Subject line\n\nBody text.\n# kept by git -m" ]
       : string);
    let t = run ~quiet:true repo (create repo) " gg" in
    let t = run repo t "ca" in
    where repo t;
    buffer repo t;
    commands repo t;
    [%expect {|
      jobs: commit g1.4
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      --- $DIR/work/.git/CHES_COMMIT_EDITMSG
      Subject line

      Body text.
      # kept by git -m

      # Write the commit message above. Lines starting with '#' are removed.
      # Space g c commits; Space g a aborts.
      #
      # On branch main
      #
      # Staged changes added to HEAD:
      #	(nothing staged)
      log: [exit 0] git rev-parse --git-path CHES_COMMIT_EDITMSG
      log: [exit 0] git log -1 --no-show-signature --format=%B HEAD --
      |}];
    let t = run repo t "A!<Esc> gc" in
    where repo t;
    head repo;
    [%expect {|
      jobs: - g1.5, refresh g1.6, diff g1.7
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      message: [main d32402d] Subject line!
      HEAD: "Subject line!\n\nBody text.\n\n"
      log: d32402d Subject line!
      status:  M a.txt
      message file: false
      |}];
    (* Aborting an amend says so. *)
    let t = run repo t "ca" in
    let t = run repo t " ga" in
    where repo t;
    head repo;
    [%expect {|
      jobs: commit g1.8
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      message: Amend aborted
      HEAD: "Subject line!\n\nBody text.\n\n"
      log: d32402d Subject line!
      status:  M a.txt
      message file: false
      |}])
;;

let%expect_test "c e extends HEAD at once, with a dirty buffer in the repository too" =
  with_repo (fun repo ->
    let t = run ~quiet:true repo (create repo) "Ax<Esc> gg" in
    let t = run repo t "ce" in
    where repo t;
    head repo;
    commands repo t;
    [%expect {|
      jobs: - g1.4, refresh g1.5
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1 dirty
      message: Not reloaded, unsaved changes: a.txt
      HEAD: "first\n\n"
      log: c8fccce first
      status:
      message file: false
      log: [exit 0] git commit --amend --no-edit
      |}])
;;

let%expect_test "a failing pre-commit hook keeps the buffer; c c reopens it; Space g a \
                 aborts; -n commits past the hook"
  =
  with_repo (fun repo ->
    let hook = repo.work ^/ ".git/hooks/pre-commit" in
    Out_channel.write_all hook ~data:"#!/bin/sh\necho 'hook says no' >&2\nexit 1\n";
    Core_unix.chmod hook ~perm:0o755;
    let t = run ~quiet:true repo (create repo) " gg" in
    let t = run repo t "cc" in
    let t = run repo t "iHooked<Esc> gc" in
    where repo t;
    head repo;
    commands repo t;
    [%expect {|
      jobs: commit g1.4
      jobs: - g1.5, refresh g1.6, diff g1.7
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: Commit failed: hook says no (exit 1)
      HEAD: "first\n\n"
      log: 42c8e24 first
      status: M  a.txt
      message file: true
      log: [exit 0] git rev-parse --git-path CHES_COMMIT_EDITMSG
      log: [exit 1] git -c 'core.commentChar=#' commit --cleanup=strip -F $DIR/work/.git/CHES_COMMIT_EDITMSG
            hook says no
      |}];
    (* Back in the view, c c reopens the pending message as it was. *)
    let t = run repo t " gg" in
    where repo t;
    let t = run repo t "cc" in
    where repo t;
    buffer repo t;
    [%expect {|
      focused vcs; tabs [a.txt *VCS: main CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: A commit message is already open: Space g c commits it, Space g a aborts
      --- $DIR/work/.git/CHES_COMMIT_EDITMSG
      Hooked
      # Write the commit message above. Lines starting with '#' are removed.
      # Space g c commits; Space g a aborts.
      #
      # On branch main
      #
      # Changes to be committed:
      #	modified:   a.txt
      |}];
    let t = run repo t " ga" in
    where repo t;
    head repo;
    [%expect {|
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      message: Commit aborted
      HEAD: "first\n\n"
      log: 42c8e24 first
      status: M  a.txt
      message file: false
      |}];
    (* The switches go with the pending message. *)
    let t = run repo t "c-nc" in
    buffer repo t;
    let after = List.length (Vcs_view.log (vcs t)) in
    let t = run repo t "iNo hooks<Esc> gc" in
    where repo t;
    head repo;
    commands ~after repo t;
    [%expect {|
      jobs: commit g1.8
      --- $DIR/work/.git/CHES_COMMIT_EDITMSG

      # Write the commit message above. Lines starting with '#' are removed.
      # Space g c commits; Space g a aborts.
      #
      # On branch main
      # Switches: --no-verify
      #
      # Changes to be committed:
      #	modified:   a.txt
      jobs: - g1.9, refresh g1.10
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      message: [main 19f6b99] No hooks
      HEAD: "No hooks\n\n"
      log: 19f6b99 No hooks | 42c8e24 first
      status:
      message file: false
      log: [exit 0] git -c 'core.commentChar=#' commit --cleanup=strip --no-verify -F $DIR/work/.git/CHES_COMMIT_EDITMSG
      |}])
;;

let%expect_test "a hook that rewrites a file: open buffers are reconciled after the commit" =
  with_repo (fun repo ->
    let hook = repo.work ^/ ".git/hooks/pre-commit" in
    Out_channel.write_all hook ~data:"#!/bin/sh\nprintf 'one\\nTWO\\nhooked\\n' > a.txt\n";
    Core_unix.chmod hook ~perm:0o755;
    let t = run ~quiet:true repo (create repo) " gg" in
    let t = run repo t "cc" in
    let t = run repo t "iHooked<Esc> gc" in
    where repo t;
    let t = run repo t "q" in
    where repo t;
    buffer repo t;
    [%expect {|
      jobs: commit g1.4
      jobs: - g1.5, refresh g1.6, diff g1.7
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      message: [main 71ee622] Hooked
      focused document; tabs [*a.txt VCS: main]; file a.txt line 1
      message: [main 71ee622] Hooked
      --- $DIR/work/a.txt
      one
      TWO
      hooked
      |}])
;;

let%expect_test "Space g c and Space g a refuse outside the pending message buffer" =
  with_repo (fun repo ->
    let t = run ~quiet:true repo (create repo) "" in
    let t = run repo t " gc" in
    where repo t;
    let t = run repo t " ga" in
    where repo t;
    (* Pending, but typed from a.txt, or from the view. *)
    let t = run ~quiet:true repo t " gg" in
    let t = run ~quiet:true repo t "cc" in
    let t = run repo t " gg" in
    let t = run repo t " gc" in
    where repo t;
    (* To a.txt's tab: the message buffer stays open, and pending. *)
    let t = run repo t "q" in
    let t = run repo t " bp" in
    let t = run repo t " bp" in
    let t = run repo t " ga" in
    where repo t;
    let t = run repo t " gc" in
    where repo t;
    head repo;
    [%expect {|
      focused document; tabs [*a.txt]; file a.txt line 1
      message: No pending commit message here; nothing ran
      focused document; tabs [*a.txt]; file a.txt line 1
      message: No pending commit message here; nothing ran
      focused vcs; tabs [a.txt *VCS: main CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: No pending commit message here; nothing ran
      focused document; tabs [*a.txt VCS: main CHES_COMMIT_EDITMSG]; file a.txt line 1
      message: No pending commit message here; nothing ran
      focused document; tabs [*a.txt VCS: main CHES_COMMIT_EDITMSG]; file a.txt line 1
      message: No pending commit message here; nothing ran
      HEAD: "first\n\n"
      log: 42c8e24 first
      status: M  a.txt
      message file: true
      |}])
;;

let%expect_test "a message buffer closed by hand is forgotten: the next c c starts afresh" =
  with_repo (fun repo ->
    let t = run ~quiet:true repo (create repo) " gg" in
    let t = run repo t "cc" in
    let t = run repo t " bc" in
    where repo t;
    let t = run repo t " gc" in
    where repo t;
    let t = run repo t " gg" in
    let t = run repo t "cc" in
    where repo t;
    buffer repo t;
    [%expect {|
      jobs: commit g1.4
      focused document; tabs [*a.txt VCS: main]; file a.txt line 1
      focused document; tabs [*a.txt VCS: main]; file a.txt line 1
      message: No pending commit message here; nothing ran
      jobs: commit g1.5
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      --- $DIR/work/.git/CHES_COMMIT_EDITMSG

      # Write the commit message above. Lines starting with '#' are removed.
      # Space g c commits; Space g a aborts.
      #
      # On branch main
      #
      # Changes to be committed:
      #	modified:   a.txt
      |}])
;;

let%expect_test "busy: c c and c e while a mutation runs; Space g c and g a while the commit \
                 runs"
  =
  with_repo (fun repo ->
    Fixture.write repo "b.txt" "BEE\n";
    let t = run ~quiet:true repo (create repo) " gg" in
    (* [s] on the Unstaged header (b.txt), its job not run yet. *)
    let t = Helpers.run ~width ~height t (Helpers.keys "s") in
    let t = Helpers.run ~width ~height t (Helpers.keys "cc") in
    where repo t;
    let t = Helpers.run ~width ~height t (Helpers.keys "ce") in
    where repo t;
    let t = run repo t "" in
    let t = run repo t "cc" in
    let t = run repo t "iBusy<Esc>" in
    let t = Helpers.run ~width ~height t (Helpers.keys " gc") in
    let t = Helpers.run ~width ~height t (Helpers.keys " gc") in
    where repo t;
    let t = Helpers.run ~width ~height t (Helpers.keys " ga") in
    where repo t;
    let t = run repo t "" in
    where repo t;
    head repo;
    [%expect {|
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      notice: Busy: Stage unstaged changes (1 file); nothing ran
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      notice: Busy: Stage unstaged changes (1 file); nothing ran
      jobs: - g1.4, refresh g1.5, diff g1.6
      jobs: commit g1.7
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: Busy: Commit; nothing ran
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: Busy: Commit; nothing ran
      jobs: - g1.8, refresh g1.9
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      message: [main 9635431] Busy
      HEAD: "Busy\n\n"
      log: 9635431 Busy | 42c8e24 first
      status:
      message file: false
      |}])
;;

let%expect_test "a failed save runs nothing and keeps the pending commit" =
  with_repo (fun repo ->
    let t = run ~quiet:true repo (create repo) " gg" in
    let t = run repo t "cc" in
    let t = run repo t "iLost<Esc>" in
    Core_unix.unlink (message_file repo);
    let t = run repo t " gc" in
    where repo t;
    printf "mutation %s\n" (Option.value (Vcs_view.mutation (vcs t)) ~default:"none");
    let t = run repo t " gc" in
    where repo t;
    head repo;
    [%expect {|
      jobs: commit g1.4
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1 dirty
      message: VCS: Missing backing file: text retained; recreate it or save as; nothing ran
      mutation none
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1 dirty
      message: VCS: Missing backing file: text retained; recreate it or save as; nothing ran
      HEAD: "first\n\n"
      log: 42c8e24 first
      status: M  a.txt
      message file: false
      |}])
;;

let%expect_test "the planner refuses at Space g c (nothing staged any more): the buffer stays" =
  with_repo (fun repo ->
    let t = run ~quiet:true repo (create repo) " gg" in
    let t = run repo t "cc" in
    let t = run repo t "iLater<Esc>" in
    (* To the view: unstage everything; back to the message. *)
    let t = run ~quiet:true repo t " gg" in
    let t = run ~quiet:true repo t "U" in
    let t = run ~quiet:true repo t " gg" in
    where repo t;
    let t = run repo t " gc" in
    where repo t;
    head repo;
    [%expect {|
      jobs: commit g1.4
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1 dirty
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1 dirty
      message: Nothing staged; stage changes first (s), or allow an empty commit (-e); nothing ran
      HEAD: "first\n\n"
      log: 42c8e24 first
      status:  M a.txt
      message file: true
      |}])
;;

let%expect_test "saving the message file does not refresh; saving a.txt does" =
  with_repo (fun repo ->
    let t = run ~quiet:true repo (create repo) " gg" in
    let t = run repo t "cc" in
    let t = run repo t "iSaved<Esc> w" in
    where repo t;
    let t = run repo t " ga" in
    let t = run repo t "q" in
    let t = run repo t "Ax<Esc> w" in
    where repo t;
    [%expect {|
      jobs: commit g1.4
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: Wrote $DIR/work/.git/CHES_COMMIT_EDITMSG (184 bytes)
      jobs: refresh g1.5, diff g1.6
      focused document; tabs [*a.txt VCS: main]; file a.txt line 1
      message: Wrote $DIR/work/a.txt (9 bytes)
      |}])
;;

let%expect_test "the tab label: the branch, or the revision when detached" =
  with_repo (fun repo ->
    let t = create repo in
    where repo t;
    let t = run ~quiet:true repo t " gg" in
    where repo t;
    ignore (Fixture.git repo [ "checkout"; "-q"; "--detach" ] : string);
    let t = run ~quiet:true repo t "gr" in
    where repo t;
    [%expect {|
      focused document; tabs [*a.txt]; file a.txt line 1
      focused vcs; tabs [a.txt *VCS: main]; file a.txt line 1
      focused vcs; tabs [a.txt *VCS: 42c8e24]; file a.txt line 1
      |}])
;;

(* {2 The view's flow with a fake planner} *)

let%expect_test "the planner gets the pending message; its refusal and a confirmation are \
                 posted, and the buffer stays"
  =
  with_repo (fun repo ->
    let planned = ref [] in
    let answer = ref (Ches_vcs.Backend.Plan.Decision.Refused "fake: not now; nothing ran") in
    let plan repository snapshot (action : B.action) =
      match action with
      | Finish_commit { kind; flags; message_file } ->
        planned
        := sprintf
             !"Finish_commit %{sexp:Ches_vcs_git.Commit.Kind.t} [%s] %s"
             kind
             (String.concat ~sep:" " flags)
             (scrub repo message_file)
           :: !planned;
        !answer
      | action -> B.plan repository snapshot action
    in
    let t = run ~quiet:true repo (create ~plan repo) " gg" in
    let t = run repo t "c-n-sc" in
    let t = run repo t " gc" in
    where repo t;
    answer
    := Confirm
         { title = "Really"
         ; message = "Really?"
         ; plan = { title = "Commit"; steps = []; rewrites_worktree = false }
         };
    let t = run repo t " gc" in
    where repo t;
    List.iter (List.rev !planned) ~f:print_endline;
    head repo;
    [%expect {|
      jobs: commit g1.4
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: fake: not now; nothing ran
      focused document; tabs [a.txt VCS: main *CHES_COMMIT_EDITMSG]; file CHES_COMMIT_EDITMSG line 1
      message: Really needs a confirmation; nothing ran
      Finish_commit Commit [--no-verify --signoff] $DIR/work/.git/CHES_COMMIT_EDITMSG
      Finish_commit Commit [--no-verify --signoff] $DIR/work/.git/CHES_COMMIT_EDITMSG
      HEAD: "first\n\n"
      log: 42c8e24 first
      status: M  a.txt
      message file: true
      |}])
;;
