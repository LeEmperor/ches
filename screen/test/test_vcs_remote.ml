(* The VCS view's remotes and branches (phase 6) end to end: the default bindings
   ([f p P r m] anywhere, [Enter n -] in Branches), git's own plans, and git run
   synchronously by [Vcs_driver] in a fixture repository whose [origin] is a local bare
   repository (a second clone pushes as another user). Fetch, pull and push with their
   popups, notices and hints; checkout, the previous branch and the name prompt; a rebase
   pull stopped on a conflict and aborted. The driver does not stream, so the streamed log
   and the progress row are fed synthetic [Output] events; the authentication failure runs
   git with a fake [GIT_SSH_COMMAND] in the job's environment. Paths under the fixture
   print as $DIR; commit hashes are reproducible. *)

open! Core
open Ches_screen
module Controller = Ches_app.Controller
module Editor = Ches_core.Editor
module View_id = Ches_tile.View_id
module Local_command = Ches_tile.Local_command
module Fixture = Ches_vcs_fixture.Fixture_repo
module Job = Ches_vcs.Job
module Event = Ches_vcs.Event

let width = 120
let height = 30

(* One commit pushed to [origin/main], its upstream. The editor opens [a.txt], with the
   default bindings. *)
let with_remote f =
  Fixture.with_repo ~remote:true (fun repo ->
    Fixture.write repo "a.txt" "one\n";
    ignore (Fixture.commit_all repo "One" : string);
    ignore (Fixture.git repo [ "push"; "-q"; "-u"; "origin"; "main" ] : string);
    f repo)
;;

let git ?cwd repo args = ignore (Fixture.git ?cwd repo args : string)

(* A second clone of the remote, in [dir/<name>]: another pusher. *)
let clone (repo : Fixture.t) name =
  let dir = Fixture.plain_dir repo name in
  git ~cwd:repo.dir repo [ "clone"; "-q"; Option.value_exn repo.remote; dir ];
  dir
;;

(* In the clone [dir]: write [path], commit it as [message], and push. *)
let push_from repo dir ~path ~contents message =
  Out_channel.write_all (Filename.concat dir path) ~data:contents;
  git ~cwd:dir repo [ "add"; "-A" ];
  git ~cwd:dir repo [ "commit"; "-q"; "-m"; message ];
  git ~cwd:dir repo [ "push"; "-q" ]
;;

(* The feedback line last printed by [where]: it shows only a new one. *)
let last_message = ref ""

let create (repo : Fixture.t) =
  last_message := "";
  let controller =
    Controller.open_file ~cell_width:Cell_map.width (Fixture.path repo "a.txt")
    |> Or_error.ok_exn
  in
  Ui_state.create
    ~tiles_visible:false
    ~views:[ Vcs_view.entry ~cwd:repo.work () ]
    controller
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

(* Events fed to the view as the runner would report them. *)
let feed t events =
  Helpers.run
    ~width
    ~height
    t
    (List.map events ~f:(fun event -> Ui_state.Input.Vcs event))
;;

let scrub (repo : Fixture.t) text =
  String.substr_replace_all text ~pattern:repo.dir ~with_:"$DIR"
;;

let vcs t = Option.value_exn (View_registry.find (Ui_state.views t) Vcs_view.key)

(* Focus, the float, the footer notice and the feedback line when it changed. *)
let where repo t =
  printf "focused %s" (View_id.to_string (Ui_state.focused_view t ~width ~height));
  Option.iter (Ui_state.popup t) ~f:(fun popup ->
    let state = Popup_tile.state popup in
    printf
      "; popup %s [%s]"
      (Popup_tile.title popup)
      (String.concat ~sep:" " state.enabled));
  Option.iter (Ui_state.confirm t) ~f:(fun confirm ->
    printf "; confirm %s" (Confirm_tile.title confirm));
  Option.iter (Ui_state.prompt t) ~f:(fun prompt ->
    printf
      "; prompt %s %S%s"
      (Prompt_tile.title prompt)
      (Prompt_tile.text prompt)
      (Option.value_map (Prompt_tile.error prompt) ~default:"" ~f:(sprintf " (error %S)")));
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
    (List.find_map
       [ Ui_state.popup_layout; Ui_state.confirm_layout; Ui_state.prompt_layout ]
       ~f:(fun layout -> layout t ~width ~height))
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

(* The command log's commands other than the refresh's, with status, output and progress. *)
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
      List.iter entry.output ~f:(fun line -> printf "      %S\n" (scrub repo line));
      Option.iter entry.progress ~f:(fun line -> printf "      progress %S\n" line)))
;;

(* Subjects of [rev]'s history, newest first, on one line. *)
let subjects ?cwd repo rev =
  Fixture.git ?cwd repo [ "log"; "--format=%s"; rev; "--" ]
  |> String.split_lines
  |> String.concat ~sep:" < "
;;

let head repo =
  printf
    "HEAD: %s; branch %s; status: %s\n"
    (subjects repo "HEAD")
    (String.strip (Fixture.git repo [ "branch"; "--show-current" ]))
    (match String.split_lines (Fixture.git repo [ "status"; "--short" ]) with
     | [] -> "clean"
     | lines -> String.concat ~sep:", " lines)
;;

let names t =
  List.map
    (Vcs_view.commands (vcs t))
    ~f:(fun (command : Local_command.t) -> command.name)
  |> String.concat ~sep:" "
;;

let%expect_test "f fetches: Fetch: done, and the summary shows the branch behind its \
                 upstream"
  =
  with_remote (fun repo ->
    let other = clone repo "other" in
    push_from repo other ~path:"o.txt" ~contents:"o\n" "Other";
    let t = run repo (create repo) " gg" in
    summary t;
    let t = run repo t "f" in
    where repo t;
    summary t;
    commands repo t;
    (* Also from the diff (outside Visual); nothing new to fetch. *)
    last_message := "";
    let t = run repo t "<Tab>f" in
    where repo t;
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      | Head: main 1d0f5bf
      | Upstream: origin/main, up to date
      jobs: - g1.3, refresh g1.4
      focused vcs
      message: Fetch: done
      | Head: main 1d0f5bf
      | Upstream: origin/main, behind 1
      log: [exit 0] git fetch --progress --prune
      jobs: - g1.5, refresh g1.6
      focused vcs
      message: Fetch: done
      |}])
;;

let%expect_test "p opens the pull popup; p fast-forwards; a diverged pull fails with the \
                 hint and changes nothing"
  =
  with_remote (fun repo ->
    let other = clone repo "other" in
    push_from repo other ~path:"o.txt" ~contents:"o\n" "Other one";
    let t = run repo (create repo) " gg" in
    let t = run repo t "p" in
    where repo t;
    float_rows t;
    let t = run repo t "p" in
    where repo t;
    summary t;
    head repo;
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      focused popup; popup Pull []
      ╭─ Pull ──────────────────────────────────────────────────╮
      │ Switches                                                │
      │   -r  Rebase local commits onto the upstream (--rebase) │
      │ Actions                                                 │
      │   p  Pull from origin/main                              │
      ╰─────────────────────────────────────────────────────────╯
      jobs: - g1.3, refresh g1.4
      focused vcs
      message: Pull from origin/main: done
      | Head: main c56a7c6
      | Upstream: origin/main, up to date
      HEAD: Other one < One; branch main; status: clean
      |}];
    push_from repo other ~path:"o.txt" ~contents:"oo\n" "Other two";
    Fixture.write repo "l.txt" "l\n";
    ignore (Fixture.commit_all repo "Local" : string);
    let t = run repo t "gr" in
    let t = run repo t "pp" in
    where repo t;
    head repo;
    commands repo t;
    [%expect
      {|
      jobs: refresh g1.5
      jobs: - g1.6, refresh g1.7
      focused vcs
      message: Pull from origin/main failed: The branch and its upstream have diverged: pull with rebase (p -r p) or merge outside Ches
      HEAD: Local < Other one < One; branch main; status: clean
      log: [exit 0] git pull --progress --ff-only --no-rebase
      log: [exit 128] git pull --progress --ff-only --no-rebase
            "hint: "
            "hint: \tgit rebase"
            "hint: "
            "hint: Disable this message with \"git config advice.diverging false\""
            "fatal: Not possible to fast-forward, aborting."
      |}])
;;

let%expect_test "P opens the push popup; P u pushes a new branch and sets its upstream" =
  with_remote (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "P" in
    where repo t;
    float_rows t;
    let t = run repo t "q" in
    git repo [ "switch"; "-q"; "-c"; "topic" ];
    let t = run repo t "gr" in
    let t = run repo t "P" in
    float_rows t;
    let t = run repo t "p" in
    where repo t;
    let t = run repo t "Pu" in
    where repo t;
    summary t;
    printf
      "branch.topic.merge %s; remote topic: %s\n"
      (String.strip (Fixture.git repo [ "config"; "branch.topic.merge" ]))
      (subjects ~cwd:(Option.value_exn repo.remote) repo "topic");
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      focused popup; popup Push main []
      ╭─ Push main ───────────────────────────────────────────────────────╮
      │ Switches                                                          │
      │   -f  Force with lease (confirmed) (--force-with-lease)           │
      │   -n  Disable hooks (--no-verify)                                 │
      │ Actions                                                           │
      │   p  Push to origin/main                                          │
      │   u  Push to origin/main, set upstream                            │
      ╰───────────────────────────────────────────────────────────────────╯
      jobs: refresh g1.3
      ╭─ Push topic ─────────────────────────────────────────────────────────────╮
      │ Switches                                                                 │
      │   -f  Force with lease (confirmed) (--force-with-lease)                  │
      │   -n  Disable hooks (--no-verify)                                        │
      │ Actions                                                                  │
      │   p  Push to upstream (none set)                                         │
      │   u  Push to origin/topic, set upstream                                  │
      ╰──────────────────────────────────────────────────────────────────────────╯
      focused vcs
      notice: topic has no upstream: P u pushes it to origin/topic and sets it; nothing ran
      jobs: - g1.4, refresh g1.5
      focused vcs
      message: Push topic to origin/topic: done
      | Head: topic 1d0f5bf
      | Upstream: origin/topic, up to date
      branch.topic.merge refs/heads/topic; remote topic: One
      |}])
;;

let%expect_test "a force push asks first: n declines, y pushes" =
  with_remote (fun repo ->
    git repo [ "commit"; "-q"; "--amend"; "-m"; "One, amended" ];
    let t = run repo (create repo) " gg" in
    let t = run repo t "P-fp" in
    where repo t;
    float_rows t;
    let t = run repo t "n" in
    where repo t;
    print_endline (subjects ~cwd:(Option.value_exn repo.remote) repo "main");
    let t = run repo t "P-fpy" in
    where repo t;
    print_endline (subjects ~cwd:(Option.value_exn repo.remote) repo "main");
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      focused confirm; confirm Force push
      ╭─ Force push ─────────────────────────────────────────────────╮
      │ Force-push main to origin/main? Commits on origin/main that  │
      │ main does not contain are lost. git refuses if origin/main   │
      │ moved since the last fetch.                                  │
      │ y yes   n no (default)                                       │
      ╰──────────────────────────────────────────────────────────────╯
      focused vcs
      One
      jobs: - g1.3, refresh g1.4
      focused vcs
      message: Force-push main to origin/main: done
      One, amended
      |}])
;;

let%expect_test "Enter checks out a branch; - goes back; a dirty buffer refuses both" =
  with_remote (fun repo ->
    git repo [ "branch"; "other" ];
    let t = run repo (create repo) " gg" in
    (* Without a previous branch, git refuses. *)
    let t = run repo t "2-" in
    where repo t;
    (* Header, main, other. A local action that succeeds posts nothing. *)
    let t = run repo t "jj<CR>" in
    where repo t;
    summary t;
    head repo;
    let t = run repo t "-" in
    where repo t;
    head repo;
    commands repo t;
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      jobs: - g1.3, refresh g1.4
      focused vcs
      message: Check out the previous branch failed: fatal: invalid reference: @{-1} (exit 128)
      jobs: - g1.5, refresh g1.6
      focused vcs
      | Head: other 1d0f5bf
      HEAD: One; branch other; status: clean
      jobs: - g1.7, refresh g1.8
      focused vcs
      HEAD: One; branch main; status: clean
      log: [exit 128] git switch -
            "fatal: invalid reference: @{-1}"
      log: [exit 0] git switch --end-of-options other
      log: [exit 0] git switch -
      |}];
    let t = run repo t "qAx<Esc> gg" in
    let t = run repo t "<CR>" in
    where repo t;
    let t = run repo t "-" in
    where repo t;
    head repo;
    [%expect
      {|
      focused vcs
      notice: Check out other refused: unsaved changes in a.txt; save or undo them first; nothing ran
      message: Check out other refused: unsaved changes in a.txt; save or undo them first; nothing ran
      focused vcs
      notice: Check out the previous branch refused: unsaved changes in a.txt; save or undo them first; nothing ran
      message: Check out the previous branch refused: unsaved changes in a.txt; save or undo them first; nothing ran
      HEAD: One; branch main; status: clean
      |}])
;;

let%expect_test "n prompts for a name: refused inline while invalid; Enter creates the \
                 branch"
  =
  with_remote (fun repo ->
    let t = run repo (create repo) " gg" in
    let t = run repo t "2n" in
    where repo t;
    let t = run repo t "a..b" in
    where repo t;
    float_rows t;
    let t = run repo t "<CR>" in
    where repo t;
    let t = run repo t "<BS><BS><BS><BS>main" in
    where repo t;
    let t = run repo t "<BS><BS><BS><BS>feature/x<CR>" in
    where repo t;
    summary t;
    head repo;
    (* Escape declines; nothing runs. *)
    let t = run repo t "nfoo<Esc>" in
    where repo t;
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      focused prompt; prompt New branch ""
      focused prompt; prompt New branch "a..b" (error "Not a valid branch name: it contains '..'")
      ╭─ New branch ─────────────────────────────────────────────╮
      │ > a..b                                                   │
      │ Not a valid branch name: it contains '..'                │
      ╰──────────────────────────────────────────────────────────╯
      focused prompt; prompt New branch "a..b" (error "Not a valid branch name: it contains '..'")
      focused prompt; prompt New branch "main" (error "A branch named main already exists")
      jobs: - g1.3, refresh g1.4
      focused vcs
      | Head: feature/x 1d0f5bf
      HEAD: One; branch feature/x; status: clean
      focused vcs
      |}])
;;

let%expect_test "n on an unborn branch is refused; the branch keys are local to Branches" =
  Fixture.with_repo (fun repo ->
    Fixture.write repo "a.txt" "one\n";
    let t = run repo (create repo) " gg" in
    let t = run repo t "2n" in
    where repo t;
    print_endline (names t);
    let t = run repo t "1" in
    print_endline (names t);
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      focused vcs
      notice: There is no commit yet: commit before branching; nothing ran
      refresh toggle-log leave focus-files focus-branches focus-commits focus-diff toggle-diff new-branch previous-branch commit fetch pull push copy next previous first last half-page-down half-page-up
      refresh toggle-log leave focus-files focus-branches focus-commits focus-diff toggle-diff toggle-fold stage unstage discard stage-all unstage-all commit fetch pull push copy next previous first last half-page-down half-page-up
      |}])
;;

let%expect_test "a rebase pull stops on a conflict: the summary says r a aborts; r a \
                 asks; y aborts"
  =
  with_remote (fun repo ->
    let other = clone repo "other" in
    push_from repo other ~path:"a.txt" ~contents:"theirs\n" "Theirs";
    Fixture.write repo "a.txt" "ours\n";
    ignore (Fixture.commit_all repo "Ours" : string);
    let t = run repo (create repo) " gg" in
    let t = run repo t "m" in
    where repo t;
    print_endline (names t);
    let t = run repo t "p-rp" in
    where repo t;
    summary t;
    commands repo t;
    print_endline (names t);
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      focused vcs
      notice: No merge in progress; nothing ran
      refresh toggle-log leave focus-files focus-branches focus-commits focus-diff toggle-diff stage unstage discard stage-all unstage-all commit fetch pull push copy next previous first last half-page-down half-page-up
      jobs: - g1.3, refresh g1.4, diff g1.5
      focused vcs
      message: Pull from origin/main (rebase) failed: error: could not apply fb912c6... Ours (exit 1)
      | Head: detached at 143c3f4
      | Rebasing main onto 143c3f4 (r a aborts)
      log: [exit 1] git pull --progress --rebase
            "hint: Resolve all conflicts manually, mark them as resolved with"
            "hint: \"git add/rm <conflicted_files>\", then run \"git rebase --continue\"."
            "hint: You can instead skip this commit: run \"git rebase --skip\"."
            "hint: To abort and get back to the state before \"git rebase\", run \"git rebase --abort\"."
            "Could not apply fb912c6... Ours"
      refresh toggle-log leave focus-files focus-branches focus-commits focus-diff toggle-diff toggle-fold stage unstage discard stage-all unstage-all commit fetch pull push rebase copy next previous first last half-page-down half-page-up
      |}];
    let t = run repo t "r" in
    where repo t;
    float_rows t;
    let t = run repo t "a" in
    where repo t;
    float_rows t;
    let t = run repo t "y" in
    where repo t;
    summary t;
    head repo;
    let t = run repo t "r" in
    where repo t;
    [%expect
      {|
      focused popup; popup Rebasing []
      ╭─ Rebasing ───────────────────╮
      │ Actions                      │
      │   a  Abort                   │
      ╰──────────────────────────────╯
      focused confirm; confirm Abort rebase
      ╭─ Abort rebase ───────────────────────────────────────────────╮
      │ Abort the rebase? The branch returns to where it was before  │
      │ the rebase; commits and conflict resolutions made during it  │
      │ are lost.                                                    │
      │ y yes   n no (default)                                       │
      ╰──────────────────────────────────────────────────────────────╯
      jobs: - g1.6, refresh g1.7
      focused vcs
      message: Reloaded from disk: a.txt
      | Head: main fb912c6
      | Upstream: origin/main, ahead 1, behind 1
      HEAD: Ours < One; branch main; status: clean
      focused vcs
      notice: No rebase in progress; nothing ran
      |}])
;;

let%expect_test "a merge stopped on a conflict: m a asks; y aborts it" =
  with_remote (fun repo ->
    git repo [ "switch"; "-q"; "-c"; "other" ];
    Fixture.write repo "a.txt" "theirs\n";
    ignore (Fixture.commit_all repo "Theirs" : string);
    git repo [ "switch"; "-q"; "main" ];
    Fixture.write repo "a.txt" "ours\n";
    ignore (Fixture.commit_all repo "Ours" : string);
    (match git repo [ "merge"; "-q"; "other" ] with
     | () -> print_endline "merged?"
     | exception _ -> print_endline "merge stopped");
    let t = run repo (create repo) " gg" in
    summary t;
    let t = run repo t "r" in
    where repo t;
    let t = run repo t "ma" in
    where repo t;
    let t = run repo t "y" in
    where repo t;
    summary t;
    head repo;
    [%expect
      {|
      merge stopped
      jobs: detect g1.1, refresh g1.2, diff g1.3
      | Head: main fb912c6
      | Upstream: origin/main, ahead 1
      | Merging 143c3f4 (m a aborts)
      focused vcs
      notice: No rebase in progress; nothing ran
      focused confirm; confirm Abort merge
      jobs: - g1.4, refresh g1.5
      focused vcs
      message: Reloaded from disk: a.txt
      | Head: main fb912c6
      | Upstream: origin/main, ahead 1
      HEAD: Ours < One; branch main; status: clean
      |}])
;;

let%expect_test "streamed lines and progress reach the log; the progress row; busy \
                 meanwhile"
  =
  with_remote (fun repo ->
    let other = clone repo "other" in
    push_from repo other ~path:"o.txt" ~contents:"o\n" "Other";
    let t = run repo (create repo) " gg@" in
    let t = keys t "f" in
    let t, jobs = Ui_state.take_vcs_jobs t in
    let job = List.hd_exn jobs in
    print_s [%sexp (Job.kind job : Ches_vcs.Exec.Kind.t)];
    let started, finished =
      List.partition_tf (Vcs_driver.events repo job) ~f:(function
        | Event.Started _ -> true
        | Output _ | Finished _ -> false)
    in
    let line ?(transient = false) ?(stream = Ches_vcs.Exec.Stream.Stderr) text =
      Event.Output { job = job.id; step = 0; stream; line = { text; transient } }
    in
    let t = feed t started in
    summary t;
    let t =
      feed
        t
        [ line "remote: Enumerating objects: 4, done.\027[K"
        ; line ~transient:true "Receiving objects:  45% (9/20)"
        ]
    in
    summary t;
    commands repo t;
    let t =
      feed
        t
        [ line ~transient:true "Receiving objects:  90% (18/20)\027[K"
        ; line "Receiving objects: 100% (20/20), done."
        ; line ~stream:Stdout "From the remote"
        ; line "   1111111..2222222  main       -> origin/main"
        ; line "four"
        ; line "five"
        ]
    in
    summary t;
    commands repo t;
    (* Both drawn escaped: the progress row and the log's line. *)
    List.filter (frame_lines t) ~f:(String.is_substring ~substring:"90%")
    |> List.iter ~f:(fun line -> print_endline (String.rstrip line));
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      Network
      | Head: main 1d0f5bf
      | Upstream: origin/main, up to date
      | Fetch...
      | Head: main 1d0f5bf
      | Upstream: origin/main, up to date
      | Fetch... Receiving objects:  45% (9/20)
      log: [running] git fetch --progress --prune
            "remote: Enumerating objects: 4, done.\027[K"
            progress "Receiving objects:  45% (9/20)"
      | Head: main 1d0f5bf
      | Upstream: origin/main, up to date
      | Fetch... Receiving objects:  90% (18/20)^[[K
      log: [running] git fetch --progress --prune
            "Receiving objects: 100% (20/20), done."
            "From the remote"
            "   1111111..2222222  main       -> origin/main"
            "four"
            "five"
            progress "Receiving objects:  90% (18/20)\027[K"
      │ Fetch... Receiving objects:  90% (18/20)^[[K  │                                                                      │|
      │     Receiving objects:  90% (18/20)^[[K                                                                              │|
      |}];
    (* The view stays usable; actions are busy. *)
    let t = keys t "2jpp" in
    where repo t;
    let t = feed t finished in
    let t, _ = Vcs_driver.settle repo t ~width ~height in
    where repo t;
    summary t;
    commands repo t;
    [%expect
      {|
      focused vcs
      notice: Busy: Fetch; nothing ran
      focused vcs
      notice: Busy: Fetch; nothing ran
      message: Fetch: done
      | Head: main 1d0f5bf
      | Upstream: origin/main, behind 1
      log: [exit 0] git fetch --progress --prune
            "Receiving objects: 100% (20/20), done."
            "From the remote"
            "   1111111..2222222  main       -> origin/main"
            "four"
            "five"
      |}])
;;

let%expect_test "an authentication failure: the hint in the notice, git's stderr in the \
                 log"
  =
  with_remote (fun repo ->
    let script = Filename.concat repo.dir "fake-ssh" in
    Out_channel.write_all
      script
      ~data:"#!/bin/sh\necho 'Permission denied (publickey).' >&2\nexit 255\n";
    Core_unix.chmod script ~perm:0o755;
    git repo [ "remote"; "set-url"; "origin"; "ssh://git@example.invalid/x.git" ];
    let t = run repo (create repo) " gg" in
    (* The runner's environment for network steps, with ssh replaced by the script. *)
    let with_ssh (job : Job.t) =
      Job.create
        ~id:job.id
        ?lane:job.lane
        (List.map job.steps ~f:(function
          | Run spec ->
            Job.Step.Run { spec with env = spec.env @ [ "GIT_SSH_COMMAND", script ] }
          | Read_file _ as step -> step))
      |> Or_error.ok_exn
    in
    let t = keys t "f" in
    let t, jobs = Ui_state.take_vcs_jobs t in
    let t =
      feed t (List.concat_map jobs ~f:(fun job -> Vcs_driver.events repo (with_ssh job)))
    in
    let t, _ = Vcs_driver.settle repo t ~width ~height in
    where repo t;
    commands repo t;
    [%expect
      {|
      jobs: detect g1.1, refresh g1.2
      focused vcs
      message: Fetch failed: SSH refused the key: is one loaded in ssh-agent (ssh-add -l)?
      log: [exit 128] git fetch --progress --prune
            "Permission denied (publickey)."
            "fatal: Could not read from remote repository."
            "Please make sure you have the correct access rights"
            "and the repository exists."
      |}])
;;
