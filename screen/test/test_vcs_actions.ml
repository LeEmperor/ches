(* The VCS view's actions (phases 3 and 4): [s u x S U] from the Files panel and the
   diff, Visual [s u x] on selected lines, confirmations, the dirty-buffer refusal and
   the staging warning, busy, failures, reconciliation of open buffers, selection and
   the diff cursor afterwards, [] [].

   The backend's planner is a fake ([Vcs_view.entry ~plan]) that records the action it
   received and returns canned decisions over real git commands, so the view's flow is
   tested apart from git's plans ([Git.Backend.plan] and [Patch] are tested in
   vcs/git). Jobs run synchronously in fixture repositories through [Vcs_driver]. *)

open! Core
open Ches_screen
open Ches_input
module Controller = Ches_app.Controller
module Editor = Ches_core.Editor
module Fixture = Ches_vcs_fixture.Fixture_repo
module Diff = Ches_vcs.Diff
module Job = Ches_vcs.Job
module Panel = Ches_vcs.Panel
module Plan = Ches_vcs.Backend.Plan
module Git = Ches_vcs_git
module B = Git.Backend
module Text_view = Ches_tile.Text_view

type env =
  { repo : Fixture.t
  ; width : int
  ; height : int
  ; planned : string list ref (** The fake planner's actions, newest first. *)
  }

let with_env ?(width = 100) ?(height = 24) f =
  Fixture.with_repo (fun repo -> f { repo; width; height; planned = ref [] })
;;

let section_name section = Panel.Section_id.to_string (B.Section.id section)

let target_name : B.Target.t -> string = function
  | File { section; path } -> sprintf "File %s %s" (section_name section) path
  | Section section -> "Section " ^ section_name section
  | Hunk { section; file; hunk; selection = Whole } ->
    sprintf "Hunk %s %s #%d" (section_name section) (Diff.File.path file) hunk
  | Hunk { section; file; hunk; selection = Lines lines } ->
    sprintf
      "Hunk %s %s #%d lines %s"
      (section_name section)
      (Diff.File.path file)
      hunk
      (String.concat ~sep:"," (List.map lines ~f:Int.to_string))
  | Lines { section; file; hunks } ->
    sprintf
      "Lines %s %s %s"
      (section_name section)
      (Diff.File.path file)
      (String.concat
         ~sep:" "
         (List.map hunks ~f:(fun (hunk, selection) ->
            match (selection : Git.Patch.Selection.t) with
            | Whole -> sprintf "#%d:whole" hunk
            | Lines lines ->
              sprintf
                "#%d:%s"
                hunk
                (String.concat ~sep:"," (List.map lines ~f:Int.to_string)))))
;;

let action_name : B.action -> string = function
  | Stage target -> "Stage " ^ target_name target
  | Unstage target -> "Unstage " ^ target_name target
  | Discard target -> "Discard " ^ target_name target
  | Stage_all -> "Stage_all"
  | Unstage_all -> "Unstage_all"
  | Finish_commit _ -> "Finish_commit"
  | Extend _ -> "Extend"
;;

(* Whole hunks as [git apply] takes them, for plain names (the fake's own [Patch]). *)
let hunks_patch (file : Diff.File.t) indices =
  let path = Diff.File.path file in
  [ sprintf "diff --git a/%s b/%s" path path; "--- a/" ^ path; "+++ b/" ^ path ]
  @ List.concat_map indices ~f:(fun index ->
    let hunk = List.nth_exn file.hunks index in
    hunk.header
    :: List.map hunk.lines ~f:(fun (line : Diff.Line.t) -> line.prefix ^ line.text))
  |> List.map ~f:(fun line -> line ^ "\n")
  |> String.concat
;;

(* The selected changes of a [Lines] target. *)
let changes (file : Diff.File.t) hunks =
  List.sum (module Int) hunks ~f:(fun (hunk, (selection : Git.Patch.Selection.t)) ->
    List.counti (List.nth_exn file.hunks hunk).lines ~f:(fun i (line : Diff.Line.t) ->
      (match line.kind with
       | Added | Removed -> true
       | Context | No_newline -> false)
      &&
      match selection with
      | Whole -> true
      | Lines lines -> List.mem lines i ~equal:Int.equal))
;;

(* The fake planner: records the action, then plans it with real commands, close to
   the contract's titles and texts. [override] answers first. *)
let fake ?(override = fun (_ : B.action) -> None) env : Vcs_view.planner =
  fun repository snapshot action ->
  env.planned := action_name action :: !(env.planned);
  match override action with
  | Some decision -> decision
  | None ->
    let cwd = Git.Repository.root repository in
    let git ?stdin args =
      Job.Step.Run (Git.Cli.mutate ?stdin ~cwd ("--literal-pathspecs" :: args))
    in
    let plan ?(rewrites_worktree = false) title steps =
      { Plan.title; steps; rewrites_worktree }
    in
    let keys sections =
      List.concat_map (B.panels snapshot) ~f:(fun (panel : _ Panel.t) ->
        List.concat_map panel.sections ~f:(fun (section : _ Panel.Section.t) ->
          if Panel.Id.equal panel.id B.files_panel
             && List.exists sections ~f:(fun s ->
               Panel.Section_id.equal (B.Section.id s) section.id)
          then List.map section.items ~f:(fun item -> item.key)
          else []))
    in
    (* The fake applies a [Lines] target's touched hunks whole; [Patch] (tested in
       vcs/git) applies only their lines. *)
    let apply_hunks flags (file : Diff.File.t) hunks =
      let stdin = Ches_vcs.Exec.Stdin.Data (hunks_patch file hunks) in
      [ git ~stdin ((("apply" :: flags) @ [ "--whitespace=nowarn"; "--check" ]))
      ; git ~stdin (("apply" :: flags) @ [ "--whitespace=nowarn" ])
      ]
    in
    let apply flags file hunk = apply_hunks flags file [ hunk ] in
    let of_lines (file : Diff.File.t) hunks =
      let n = changes file hunks in
      sprintf "%d line%s of %s" n (if n = 1 then "" else "s") (Diff.File.path file)
    in
    let of_hunk (file : Diff.File.t) hunk =
      sprintf "hunk %d/%d of %s" (hunk + 1) (List.length file.hunks) (Diff.File.path file)
    in
    let files n = sprintf "%d file%s" n (if n = 1 then "" else "s") in
    (match action with
     | Stage (File { section = Conflicted; path }) ->
       Run (plan (sprintf "Mark %s resolved" path) [ git [ "add"; "--all"; "--"; path ] ])
     | Stage (File { section = Unstaged | Untracked; path }) ->
       Run (plan ("Stage " ^ path) [ git [ "add"; "--all"; "--"; path ] ])
     | Stage (Section ((Unstaged | Untracked) as section)) ->
       let keys = keys [ section ] in
       Run
         (plan
            (sprintf "Stage %s (%s)" (section_name section) (files (List.length keys)))
            [ git ("add" :: "--all" :: "--" :: keys) ])
     | Stage_all ->
       let keys = keys [ Unstaged; Untracked ] in
       if List.is_empty keys
       then Refused "Nothing to stage; nothing ran"
       else
         Run
           (plan
              (sprintf "Stage all changes (%s)" (files (List.length keys)))
              [ git ("add" :: "--all" :: "--" :: keys) ])
     | Stage (Hunk { section = Unstaged; file; hunk; _ }) ->
       Run (plan ("Stage " ^ of_hunk file hunk) (apply [ "--cached" ] file hunk))
     | Stage (File { path; _ }) -> Refused (path ^ " is already staged; nothing ran")
     | Unstage (File { section = Staged; path }) ->
       Run (plan ("Unstage " ^ path) [ git [ "restore"; "--staged"; "--"; path ] ])
     | Unstage (Hunk { section = Staged; file; hunk; _ }) ->
       Run (plan ("Unstage " ^ of_hunk file hunk) (apply [ "--cached"; "--reverse" ] file hunk))
     | Unstage_all | Unstage (Section Staged) ->
       let keys = keys [ Staged ] in
       Run
         (plan
            (sprintf "Unstage all changes (%s)" (files (List.length keys)))
            [ git ("restore" :: "--staged" :: "--" :: keys) ])
     | Unstage (File { path; _ }) -> Refused (path ^ " is not staged; nothing ran")
     | Discard (File { section = Unstaged; path }) ->
       Confirm
         { title = "Discard changes"
         ; message =
             sprintf
               "Discard the unstaged changes to %s? They are lost; staged changes are kept."
               path
         ; plan =
             plan ~rewrites_worktree:true ("Discard unstaged changes to " ^ path)
               [ git [ "restore"; "--worktree"; "--"; path ] ]
         }
     | Discard (File { section = Untracked; path }) ->
       Confirm
         { title = "Delete untracked file"
         ; message = sprintf "Delete %s? It is not in git and cannot be recovered." path
         ; plan =
             plan ~rewrites_worktree:true ("Delete " ^ path)
               [ git [ "clean"; "--force"; "--quiet"; "--"; path ] ]
         }
     | Discard (Hunk { section = Unstaged; file; hunk; _ }) ->
       Confirm
         { title = "Discard hunk"
         ; message = sprintf "Discard %s? Its unstaged lines are lost." (of_hunk file hunk)
         ; plan =
             plan ~rewrites_worktree:true ("Discard " ^ of_hunk file hunk)
               (apply [ "--reverse" ] file hunk)
         }
     | Stage (Lines { section = Untracked; _ }) | Discard (Lines { section = Untracked; _ })
       -> Refused "Stage the whole untracked file first (s on its row); nothing ran"
     | Stage (Lines { file; hunks; _ })
     | Unstage (Lines { file; hunks; _ })
     | Discard (Lines { file; hunks; _ })
       when changes file hunks = 0 -> Refused "No changes selected; nothing ran"
     | Stage (Lines { section = Unstaged; file; hunks }) ->
       Run
         (plan
            ("Stage " ^ of_lines file hunks)
            (apply_hunks [ "--cached" ] file (List.map hunks ~f:fst)))
     | Unstage (Lines { section = Staged; file; hunks }) ->
       Run
         (plan
            ("Unstage " ^ of_lines file hunks)
            (apply_hunks [ "--cached"; "--reverse" ] file (List.map hunks ~f:fst)))
     | Unstage (Lines { file; _ }) ->
       Refused (Diff.File.path file ^ " is not staged; nothing ran")
     | Discard (Lines { section = Unstaged; file; hunks }) ->
       Confirm
         { title = "Discard lines"
         ; message =
             sprintf "Discard %s? Their unstaged changes are lost." (of_lines file hunks)
         ; plan =
             plan ~rewrites_worktree:true ("Discard " ^ of_lines file hunks)
               (apply_hunks [ "--reverse" ] file (List.map hunks ~f:fst))
         }
     | Stage _ | Unstage _ | Discard _ | Finish_commit _ | Extend _ ->
       Refused "fake: not planned; nothing ran")
;;

(* The editor on [file] as it is on disk, the VCS view (with the fake planner)
   focused through [Space v x]. *)
let create ?override ?(file = "a.txt") env =
  let leader_v c = [ Key.char ' '; Key.char 'v'; Key.char c ] in
  let bindings =
    Bindings.create
      (Bindings.to_list Bindings.default
       @ [ leader_v 'x', Bindings.Target.View (Focus_view Vcs_view.id) ])
    |> Or_error.ok_exn
  in
  let path = Fixture.path env.repo file in
  let editor =
    Controller.editor (Ui_state.controller (Helpers.ui ~path (In_channel.read_all path)))
  in
  Ui_state.create
    ~tiles_visible:false
    ~views:[ Vcs_view.entry ~plan:(fake ?override env) ~cwd:env.repo.work () ]
    (Controller.create ~keymap_config:{ Keymap.Config.default with normal = bindings } editor)
;;

let relative env text = String.substr_replace_all text ~pattern:env.repo.dir ~with_:"$DIR"
let keys env t keys = Helpers.run ~width:env.width ~height:env.height t (Helpers.keys keys)

(* Keys, then every job they cause run to completion. *)
let run env t keys_ =
  fst (Vcs_driver.settle env.repo (keys env t keys_) ~width:env.width ~height:env.height)
;;

let state t = Option.value_exn (View_registry.find (Ui_state.views t) Vcs_view.key)
let git env args = ignore (Fixture.git env.repo args : string)
let commit env message = ignore (Fixture.commit_all env.repo message : string)

let status env =
  printf "status: %s\n"
    (String.concat ~sep:", " (String.split_lines (Fixture.git env.repo [ "status"; "--short" ])))
;;

let position : Panel.Position.t option -> string = function
  | None -> "none"
  | Some (Header section) -> "header " ^ Panel.Section_id.to_string section
  | Some (Item { section; key }) -> sprintf "%s %s" (Panel.Section_id.to_string section) key
;;

let diff_state : Vcs_view.Diff_state.t -> string = function
  | Empty -> "empty"
  | No_diff -> "no diff"
  | Loading target -> "loading " ^ Sexp.to_string [%sexp (target : B.diff_target)]
  | Loaded (target, _) -> Sexp.to_string [%sexp (target : B.diff_target)]
  | Failed (target, _) -> "failed " ^ Sexp.to_string [%sexp (target : B.diff_target)]
;;

(* What happened: the planned actions since the last report, the question, the
   notices, the selection, the diff and whether a mutation is pending. *)
let report env t =
  let v = state t in
  List.iter (List.rev !(env.planned)) ~f:(printf "planned: %s\n");
  env.planned := [];
  Option.iter (Ui_state.confirm t) ~f:(fun confirm ->
    printf "confirm: %s: %s\n" (Confirm_tile.title confirm) (Confirm_tile.message confirm));
  Option.iter (Ui_state.capture_notice t) ~f:(printf "notice: %s\n");
  Option.iter (Ui_state.message t) ~f:(fun message ->
    if not (String.equal message.text "VCS focused") then printf "message: %s\n" message.text);
  printf "%s: %s; diff %s%s\n"
    (Sexp.to_string [%sexp (Vcs_view.focus v : Vcs_view.Focus.t)])
    (position (Vcs_view.cursor v (Vcs_view.list_focus v)).selected)
    (diff_state (Vcs_view.diff v))
    (Option.value_map (Vcs_view.mutation v) ~default:"" ~f:(sprintf "; mutation %S"))
;;

(* The log's mutation commands (not the reads). *)
let print_log env t =
  List.iter (Vcs_view.log (state t)) ~f:(fun (entry : Vcs_view.Log_entry.t) ->
    let command =
      String.chop_prefix_if_exists entry.command
        ~prefix:(String.concat ~sep:" " ("git" :: Git.Cli.prefix) ^ " ")
    in
    if String.is_prefix command ~prefix:"--literal-pathspecs"
    then
      printf "log: [%s] %s%s\n"
        (Option.value entry.status ~default:"running")
        command
        (String.concat (List.map entry.output ~f:(fun line -> "\n       " ^ relative env line))))
;;

let diff_view t = Option.value_exn (Vcs_view.text_view (state t))

(* The diff cursor's line number and text. *)
let diff_cursor t =
  let view = diff_view t in
  let text = Text_view.text view in
  let before = String.prefix text (Text_view.cursor view) in
  let line = String.count before ~f:(Char.equal '\n') in
  sprintf "cursor line %d: %s" line (List.nth_exn (String.split_lines text) line)
;;

let print_diff t =
  String.split_lines (Text_view.text (diff_view t))
  |> List.iteri ~f:(fun i line -> printf "%2d|%s\n" i line)
;;

let editor t =
  let editor = Controller.editor (Ui_state.controller t) in
  printf "editor %s: %S, dirty %b, missing %b\n"
    (Option.value_map (Editor.path editor) ~default:"none" ~f:Filename.basename)
    (Ches_core.Text_buffer.to_string (Editor.text editor))
    (Editor.is_dirty editor)
    (Controller.is_missing (Ui_state.controller t))
;;

(* A commit, then: a.txt modified (unstaged), b.txt staged, new.txt untracked. *)
let changes env =
  Fixture.write env.repo "a.txt" "one\ntwo\nthree\n";
  Fixture.write env.repo "b.txt" "bee\n";
  commit env "First";
  Fixture.write env.repo "a.txt" "one\nTWO\nthree\n";
  Fixture.write env.repo "b.txt" "bee\nsting\n";
  git env [ "add"; "b.txt" ];
  Fixture.write env.repo "new.txt" "fresh\n"
;;

let%expect_test "s, u and S U in the Files panel: one job each, then a refresh; the \
                 selection moves on"
  =
  with_env (fun env ->
    changes env;
    let t = run env (create env) " vx" in
    (* Rows: untracked header, new.txt, unstaged header, a.txt, staged header, b.txt. *)
    let t = run env t "jjj" in
    report env t;
    let t = run env t "s" in
    report env t;
    status env;
    print_log env t;
    [%expect
      {|
      Files: unstaged a.txt; diff (Unstaged(a.txt))
      planned: Stage File unstaged a.txt
      Files: header staged; diff (Staged())
      status: M  a.txt, M  b.txt, ?? new.txt
      log: [exit 0] --literal-pathspecs add --all -- a.txt
      |}];
    (* The staged header: [u] unstages the section; [s] on it is refused. *)
    let t = run env t "s" in
    report env t;
    let t = run env t "u" in
    report env t;
    status env;
    [%expect
      {|
      planned: Stage Section staged
      notice: fake: not planned; nothing ran
      Files: header staged; diff (Staged())
      planned: Unstage Section staged
      Files: header untracked; diff no diff
      status:  M a.txt,  M b.txt, ?? new.txt
      |}];
    (* An item: the next one of its section is selected after it leaves. *)
    let t = run env t "jjjs" in
    report env t;
    status env;
    let t = run env t "U" in
    report env t;
    let t = run env t "S" in
    report env t;
    status env;
    let t = run env t "U" in
    report env t;
    status env;
    [%expect
      {|
      planned: Stage File unstaged a.txt
      Files: unstaged b.txt; diff (Unstaged(b.txt))
      status: M  a.txt,  M b.txt, ?? new.txt
      planned: Unstage_all
      Files: unstaged b.txt; diff (Unstaged(b.txt))
      planned: Stage_all
      Files: header staged; diff (Staged())
      status: M  a.txt, M  b.txt, A  new.txt
      planned: Unstage_all
      Files: header untracked; diff no diff
      status:  M a.txt,  M b.txt, ?? new.txt
      |}];
    (* The section header of untracked files, then S with nothing to stage. *)
    let t = run env t "s" in
    report env t;
    let t = run env t "S" in
    report env t;
    let t = run env t "S" in
    report env t;
    [%expect
      {|
      planned: Stage Section untracked
      Files: header unstaged; diff (Unstaged())
      planned: Stage_all
      Files: header staged; diff (Staged())
      planned: Stage_all
      notice: Nothing to stage; nothing ran
      Files: header staged; diff (Staged())
      |}])
;;

let%expect_test "x asks first (default No); y runs it and reloads the open buffer" =
  with_env (fun env ->
    changes env;
    let t = run env (run env (create env) " vx") "jjj" in
    let t = run env t "x" in
    report env t;
    let t = run env t "n" in
    report env t;
    status env;
    [%expect
      {|
      planned: Discard File unstaged a.txt
      confirm: Discard changes: Discard the unstaged changes to a.txt? They are lost; staged changes are kept.
      Files: unstaged a.txt; diff (Unstaged(a.txt))
      Files: unstaged a.txt; diff (Unstaged(a.txt))
      status:  M a.txt, M  b.txt, ?? new.txt
      |}];
    let t = run env t "x" in
    let t = run env t "y" in
    report env t;
    status env;
    print_log env t;
    (* The editor's clean buffer of a.txt was reconciled with the restored file. *)
    let t = run env t "q" in
    editor t;
    [%expect
      {|
      planned: Discard File unstaged a.txt
      message: Reloaded from disk: a.txt
      Files: header staged; diff (Staged())
      status: M  b.txt, ?? new.txt
      log: [exit 0] --literal-pathspecs restore --worktree -- a.txt
      editor a.txt: "one\ntwo\nthree\n", dirty false, missing false
      |}])
;;

let%expect_test "deleting an untracked file marks its open buffer missing" =
  with_env (fun env ->
    changes env;
    let t = run env (run env (create ~file:"new.txt" env) " vx") "j" in
    let t = run env t "xy" in
    report env t;
    status env;
    let t = run env t "q" in
    editor t;
    [%expect
      {|
      planned: Discard File untracked new.txt
      message: Deleted on disk (kept, marked missing): new.txt
      Files: header unstaged; diff (Unstaged())
      status:  M a.txt, M  b.txt
      editor new.txt: "fresh\n", dirty false, missing true
      |}])
;;

let%expect_test "a work-tree rewrite is refused while a buffer in the repository is \
                 dirty, before any question and again on y; staging warns"
  =
  with_env (fun env ->
    changes env;
    (* Unsaved text in the editor's a.txt. *)
    let t = run env (run env (create env) "ix<Esc> vx") "jjj" in
    let t = run env t "x" in
    report env t;
    status env;
    [%expect
      {|
      planned: Discard File unstaged a.txt
      notice: Discard unstaged changes to a.txt refused: unsaved changes in a.txt; save or undo them first; nothing ran
      message: Discard unstaged changes to a.txt refused: unsaved changes in a.txt; save or undo them first; nothing ran
      Files: unstaged a.txt; diff (Unstaged(a.txt))
      status:  M a.txt, M  b.txt, ?? new.txt
      |}];
    (* Any discard, even of another file; staging a.txt runs with a warning. *)
    let t = run env t "kkx" in
    report env t;
    let t = run env t "jjs" in
    report env t;
    status env;
    [%expect
      {|
      planned: Discard File untracked new.txt
      notice: Delete new.txt refused: unsaved changes in a.txt; save or undo them first; nothing ran
      message: Delete new.txt refused: unsaved changes in a.txt; save or undo them first; nothing ran
      Files: untracked new.txt; diff (Untracked new.txt)
      planned: Stage File unstaged a.txt
      notice: a.txt has unsaved changes: the saved files were staged, not the buffers
      message: a.txt has unsaved changes: the saved files were staged, not the buffers
      Files: header staged; diff (Staged())
      status: M  a.txt, M  b.txt, ?? new.txt
      |}];
    (* From the staged header: unstage both, then S names a.txt again. *)
    let t = run env t "u" in
    let t = run env t "S" in
    report env t;
    let t = run env t "U" in
    report env t;
    [%expect
      {|
      planned: Unstage Section staged
      planned: Stage_all
      notice: a.txt has unsaved changes: the saved files were staged, not the buffers
      message: a.txt has unsaved changes: the saved files were staged, not the buffers
      Files: header staged; diff (Staged())
      planned: Unstage_all
      message: a.txt has unsaved changes: the saved files were staged, not the buffers
      Files: header untracked; diff no diff
      |}]);
  (* The answer's context is checked again: a buffer that became dirty while the
     question was up refuses the confirmed plan. *)
  with_env (fun env ->
    changes env;
    let t = run env (run env (create env) " vx") "jjjx" in
    report env t;
    let dirty =
      View_registry.Context.create (fun () ->
        [ { path = Fixture.path env.repo "b.txt"
          ; label = "b.txt"
          ; dirty = true
          ; missing = false
          }
        ])
    in
    let views, outcome =
      View_registry.answer
        (Ui_state.views t)
        Vcs_view.id
        Yes
        ~controller:(Ui_state.controller t)
        ~context:dirty
        ~rows:20
        ~width:98
    in
    let outcome = Option.value_exn outcome in
    printf "notice: %s; jobs %d; mutation %s\n"
      (match outcome.notice with
       | Some (`Post text) -> "post " ^ text
       | Some (`Show text) -> "show " ^ text
       | None -> "none")
      (List.length outcome.jobs)
      (Option.value
         (Vcs_view.mutation (Option.value_exn (View_registry.find views Vcs_view.key)))
         ~default:"none");
    [%expect
      {|
      planned: Discard File unstaged a.txt
      confirm: Discard changes: Discard the unstaged changes to a.txt? They are lost; staged changes are kept.
      Files: unstaged a.txt; diff (Unstaged(a.txt))
      notice: post Discard unstaged changes to a.txt refused: unsaved changes in b.txt; save or undo them first; nothing ran; jobs 0; mutation none
      |}])
;;

let%expect_test "busy until the refresh after a mutation is applied; failures are \
                 posted; a failed rewrite still reconciles"
  =
  with_env (fun env ->
    changes env;
    let t = run env (run env (create env) " vx") "jjj" in
    (* Jobs stay queued: the mutation is in flight. *)
    let t = keys env t "s" in
    report env t;
    let t = keys env t "x" in
    report env t;
    let step t =
      let t, ran = Vcs_driver.step env.repo t ~width:env.width ~height:env.height in
      printf "ran: [%s]\n" (String.concat ~sep:"; " (List.map ran ~f:Vcs_driver.describe));
      t
    in
    (* The mutation finished; its refresh is queued: still busy. *)
    let t = step t in
    let t = keys env t "S" in
    report env t;
    let t = step t in
    report env t;
    ignore (step t : Ui_state.t);
    status env;
    [%expect
      {|
      planned: Stage File unstaged a.txt
      Files: unstaged a.txt; diff (Unstaged(a.txt)); mutation "Stage a.txt"
      notice: Busy: Stage a.txt; nothing ran
      Files: unstaged a.txt; diff (Unstaged(a.txt)); mutation "Stage a.txt"
      ran: [- g1.6]
      notice: Busy: Stage a.txt; nothing ran
      Files: unstaged a.txt; diff (Unstaged(a.txt)); mutation "Stage a.txt"
      ran: [refresh g1.7]
      notice: Busy: Stage a.txt; nothing ran
      Files: header staged; diff loading (Staged())
      ran: [diff g1.8]
      status: M  a.txt, M  b.txt, ?? new.txt
      |}]);
  with_env (fun env ->
    changes env;
    let cwd = env.repo.work in
    let git args = Job.Step.Run (Git.Cli.mutate ~cwd ("--literal-pathspecs" :: args)) in
    let override : B.action -> Plan.Decision.t option = function
      | Stage _ ->
        Some
          (Run
             { title = "Stage a.txt"
             ; steps = [ git [ "add"; "--all"; "--"; "missing.txt" ] ]
             ; rewrites_worktree = false
             })
      | Discard _ ->
        (* The first step rewrites a.txt, the second fails. *)
        Some
          (Confirm
             { title = "Discard changes"
             ; message = "Discard?"
             ; plan =
                 { title = "Discard unstaged changes to a.txt"
                 ; steps =
                     [ git [ "restore"; "--worktree"; "--"; "a.txt" ]
                     ; git [ "restore"; "--worktree"; "--"; "missing.txt" ]
                     ]
                 ; rewrites_worktree = true
                 }
             })
      | Unstage _ -> Some (Refused "a.txt is not staged; nothing ran")
      | Stage_all | Unstage_all | Finish_commit _ | Extend _ -> None
    in
    let t = run env (run env (create ~override env) " vx") "jjj" in
    let t = run env t "s" in
    report env t;
    print_log env t;
    let t = run env t "u" in
    report env t;
    let t = run env t "xy" in
    report env t;
    status env;
    let t = run env t "q" in
    editor t);
  [%expect
    {|
    planned: Stage File unstaged a.txt
    message: Stage a.txt failed: fatal: pathspec 'missing.txt' did not match any files (exit 128)
    Files: unstaged a.txt; diff (Unstaged(a.txt))
    log: [exit 128] --literal-pathspecs add --all -- missing.txt
           fatal: pathspec 'missing.txt' did not match any files
    planned: Unstage File unstaged a.txt
    notice: a.txt is not staged; nothing ran
    message: Stage a.txt failed: fatal: pathspec 'missing.txt' did not match any files (exit 128)
    Files: unstaged a.txt; diff (Unstaged(a.txt))
    planned: Discard File unstaged a.txt
    message: Discard unstaged changes to a.txt failed: error: pathspec 'missing.txt' did not match any file(s) known to git (exit 1)
    Files: header staged; diff (Staged())
    status: M  b.txt, ?? new.txt
    editor a.txt: "one\ntwo\nthree\n", dirty false, missing false
    |}]
;;

(* One file of twelve lines, committed, then changed at both ends: two hunks. *)
let two_hunks env =
  let lines = List.init 12 ~f:(fun i -> sprintf "line %d" (i + 1)) in
  let text lines = String.concat (List.map lines ~f:(fun line -> line ^ "\n")) in
  Fixture.write env.repo "a.txt" (text lines);
  commit env "First";
  Fixture.write
    env.repo
    "a.txt"
    (text
       (List.mapi lines ~f:(fun i line ->
          if i = 0 || i = 11 then String.uppercase line else line)))
;;

let%expect_test "] and [ move between hunks, with counts" =
  with_env (fun env ->
    two_hunks env;
    let t = run env (run env (create env) " vx") "j<Tab>" in
    print_diff t;
    List.fold [ "]"; "]"; "]"; "["; "["; "["; "3]"; "gg"; "2]"; "k["; "j]" ] ~init:t
      ~f:(fun t keys_ ->
        let t = run env t keys_ in
        printf "%-3s %s\n" keys_ (diff_cursor t);
        t)
    |> ignore);
  [%expect
    {|
     0|diff --git a/a.txt b/a.txt
     1|index 624b469..3a02108 100644
     2|--- a/a.txt
     3|+++ b/a.txt
     4|@@ -1,4 +1,4 @@
     5|-line 1
     6|+LINE 1
     7| line 2
     8| line 3
     9| line 4
    10|@@ -9,4 +9,4 @@ line 8
    11| line 9
    12| line 10
    13| line 11
    14|-line 12
    15|+LINE 12
    ]   cursor line 4: @@ -1,4 +1,4 @@
    ]   cursor line 10: @@ -9,4 +9,4 @@ line 8
    ]   cursor line 10: @@ -9,4 +9,4 @@ line 8
    [   cursor line 4: @@ -1,4 +1,4 @@
    [   cursor line 4: @@ -1,4 +1,4 @@
    [   cursor line 4: @@ -1,4 +1,4 @@
    3]  cursor line 10: @@ -9,4 +9,4 @@ line 8
    gg  cursor line 0: diff --git a/a.txt b/a.txt
    2]  cursor line 10: @@ -9,4 +9,4 @@ line 8
    k[  cursor line 4: @@ -1,4 +1,4 @@
    j]  cursor line 10: @@ -9,4 +9,4 @@ line 8
    |}]
;;

let%expect_test "s u x in the diff act on the hunk at the cursor, or the file on its \
                 header; the cursor goes to the hunk that took its place"
  =
  with_env (fun env ->
    two_hunks env;
    let t = run env (run env (create env) " vx") "j<Tab>" in
    (* On a line of the first hunk. *)
    let t = run env t "]jj" in
    let t = run env t "s" in
    report env t;
    printf "%s\n" (diff_cursor t);
    print_endline (Fixture.git env.repo [ "diff"; "--cached"; "--stat" ]);
    [%expect
      {|
      planned: Stage Hunk unstaged a.txt #0
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      cursor line 4: @@ -9,4 +9,4 @@ line 8
       a.txt | 2 +-
       1 file changed, 1 insertion(+), 1 deletion(-)
      |}];
    (* The last hunk leaves: the selection moves to the staged header and the diff
       starts at the top. *)
    let t = run env t "s" in
    report env t;
    printf "%s\n" (diff_cursor t);
    status env;
    [%expect
      {|
      planned: Stage Hunk unstaged a.txt #0
      Diff: header staged; diff (Staged())
      cursor line 0: diff --git a/a.txt b/a.txt
      status: M  a.txt
      |}];
    (* Unstaging the second of two staged hunks: the file's last hunk, clamped. *)
    let t = run env t "2]u" in
    report env t;
    printf "%s\n" (diff_cursor t);
    [%expect
      {|
      planned: Unstage Hunk staged a.txt #1
      Diff: header staged; diff (Staged())
      cursor line 4: @@ -1,4 +1,4 @@
      |}];
    (* A file header line acts on the file; x on it asks. *)
    let t = run env t "ggu" in
    report env t;
    status env;
    let t = run env t "<Tab>jj<Tab>gg" in
    let t = run env t "x" in
    report env t;
    [%expect
      {|
      planned: Unstage File staged a.txt
      Diff: header unstaged; diff (Unstaged())
      status:  M a.txt
      planned: Discard File unstaged a.txt
      confirm: Discard changes: Discard the unstaged changes to a.txt? They are lost; staged changes are kept.
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      |}];
    (* Discarding a hunk asks; y discards it from the work tree. *)
    let t = run env t "<Esc>]x" in
    report env t;
    let t = run env t "y" in
    report env t;
    print_endline (Fixture.git env.repo [ "diff" ]);
    [%expect
      {|
      planned: Discard Hunk unstaged a.txt #0
      confirm: Discard hunk: Discard hunk 1/2 of a.txt? Its unstaged lines are lost.
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      message: Reloaded from disk: a.txt
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      diff --git a/a.txt b/a.txt
      index 624b469..872f606 100644
      --- a/a.txt
      +++ b/a.txt
      @@ -9,4 +9,4 @@ line 8
       line 9
       line 10
       line 11
      -line 12
      +LINE 12
      |}])
;;

let%expect_test "nothing to act on: a commit's diff, a loading diff, header lines in \
                 Visual; what help lists there"
  =
  with_env (fun env ->
    two_hunks env;
    let t = run env (run env (create env) " vx") "j" in
    let names t =
      List.filter_map (Vcs_view.commands (state t)) ~f:(fun command ->
        Option.some_if
          (List.mem
             [ "stage"; "unstage"; "discard"; "stage-all"; "unstage-all"; "next-hunk"
             ; "previous-hunk" ]
             command.name
             ~equal:String.equal)
          command.name)
      |> String.concat ~sep:" "
      |> printf "commands: %s\n"
    in
    (* The diff is still loading: keys only. *)
    let t = keys env t "k<Tab>" in
    let t = keys env t "j" in
    let t = keys env t "s" in
    report env t;
    names t;
    let t = run env t "" in
    names t;
    let t = run env t "vs" in
    report env t;
    names t;
    let t = run env (run env t "<Esc><Esc>3j<Tab>") "x" in
    report env t;
    names t;
    let t = run env t "<Tab>" in
    names t;
    let t = run env t "<Tab>s" in
    report env t;
    let t = run env t "<Tab>2" in
    names t);
  [%expect {|
    notice: The diff is still loading
    Diff: header unstaged; diff loading (Unstaged())
    commands: stage-all unstage-all next-hunk previous-hunk
    commands: stage unstage discard stage-all unstage-all next-hunk previous-hunk
    planned: Stage Lines unstaged a.txt
    notice: No changes selected; nothing ran
    Diff: header unstaged; diff (Unstaged())
    commands: stage unstage discard stage-all unstage-all
    notice: Nothing to discard here: a commit's diff
    Diff: recent 4b26c4706468e2271f1d7fb1229d054406fdf98f; diff (Commit 4b26c4706468e2271f1d7fb1229d054406fdf98f)
    commands: stage-all unstage-all next-hunk previous-hunk
    commands:
    notice: Nothing to stage here: a commit's diff
    Diff: recent 4b26c4706468e2271f1d7fb1229d054406fdf98f; diff (Commit 4b26c4706468e2271f1d7fb1229d054406fdf98f)
    commands:
    |}]
;;

(* {2 Visual s u x on selected lines (phase 4)} *)

let visual t =
  printf "visual: %s\n"
    (Option.value_map (Text_view.visual (diff_view t)) ~default:"none" ~f:(fun kind ->
       Sexp.to_string [%sexp (kind : Text_view.Kind.t)]))
;;

let line_commands t =
  List.iter (Vcs_view.commands (state t)) ~f:(fun (command : Ches_tile.Local_command.t) ->
    if List.mem [ "stage"; "unstage"; "discard" ] command.name ~equal:String.equal
    then printf "command %s (%s): %s\n" command.name
           (Ches_tile.Local_command.keys_hum command) command.description)
;;

let%expect_test "Visual s acts on the selected lines; a refusal keeps Visual, running \
                 ends it; the cursor goes to the hunk that took the first one's place"
  =
  with_env (fun env ->
    two_hunks env;
    let t = run env (run env (create env) " vx") "j<Tab>" in
    (* The file's header and the first @@ line: an empty [Lines], the planner's
       refusal. *)
    let t = run env t "Vjjjj" in
    line_commands t;
    let t = run env t "s" in
    report env t;
    visual t;
    [%expect
      {|
      command stage (s): Stage the selected lines (one file)
      command unstage (u): Unstage the selected lines (one file)
      command discard (x): Discard the selected lines (one file); confirmed
      planned: Stage Lines unstaged a.txt
      notice: No changes selected; nothing ran
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      visual: Linewise
      |}];
    (* Context lines only; then u in a diff of unstaged changes. *)
    let t = run env t "<Esc>3jVjs" in
    report env t;
    visual t;
    let t = run env t "<Esc>kkVju" in
    report env t;
    visual t;
    [%expect
      {|
      planned: Stage Lines unstaged a.txt #0:2,3
      notice: No changes selected; nothing ran
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      visual: Linewise
      planned: Unstage Lines unstaged a.txt #0:1,2
      notice: a.txt is not staged; nothing ran
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      visual: Linewise
      |}];
    (* An added line and a context line of the first hunk. *)
    let t = run env t "s" in
    report env t;
    visual t;
    printf "%s\n" (diff_cursor t);
    print_log env t;
    print_endline (Fixture.git env.repo [ "diff"; "--cached"; "--stat" ]);
    [%expect
      {|
      planned: Stage Lines unstaged a.txt #0:1,2
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      visual: none
      cursor line 4: @@ -9,4 +9,4 @@ line 8
      log: [exit 0] --literal-pathspecs apply --cached --whitespace=nowarn --check
      log: [exit 0] --literal-pathspecs apply --cached --whitespace=nowarn
       a.txt | 2 +-
       1 file changed, 1 insertion(+), 1 deletion(-)
      |}];
    (* S and U keep working in Visual, on everything. *)
    let t = run env t "VU" in
    report env t;
    visual t;
    status env;
    [%expect
      {|
      planned: Unstage_all
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      visual: none
      status:  M a.txt
      |}])
;;

let%expect_test "Visual x across two hunks: one target, confirmed; the question ends \
                 Visual whatever the answer"
  =
  with_env (fun env ->
    two_hunks env;
    let t = run env (run env (create ~file:"a.txt" env) " vx") "j<Tab>" in
    (* Characterwise, from the middle of "-line 1" to the middle of "-line 12". *)
    let t = run env t "5jllv9j" in
    let t = run env t "x" in
    report env t;
    visual t;
    let t = run env t "n" in
    report env t;
    status env;
    [%expect
      {|
      planned: Discard Lines unstaged a.txt #0:0,1,2,3,4 #1:0,1,2,3
      confirm: Discard lines: Discard 3 lines of a.txt? Their unstaged changes are lost.
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      visual: none
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      status:  M a.txt
      |}];
    let t = run env t "gg5jllv9jx" in
    report env t;
    let t = run env t "y" in
    report env t;
    status env;
    let t = run env t "q" in
    editor t;
    [%expect
      {|
      planned: Discard Lines unstaged a.txt #0:0,1,2,3,4 #1:0,1,2,3
      confirm: Discard lines: Discard 3 lines of a.txt? Their unstaged changes are lost.
      Diff: unstaged a.txt; diff (Unstaged(a.txt))
      message: Reloaded from disk: a.txt
      Diff: none; diff empty
      status:
      editor a.txt: "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\nline 11\nline 12\n", dirty false, missing false
      |}])
;;

(* Two committed files, both changed: one unstaged diff with two files. *)
let two_files env =
  Fixture.write env.repo "a.txt" "one\ntwo\nthree\n";
  Fixture.write env.repo "c.txt" "sea\n";
  commit env "First";
  Fixture.write env.repo "a.txt" "one\nTWO\nthree\n";
  Fixture.write env.repo "c.txt" "SEA\n"
;;

let%expect_test "Visual across files is refused; busy, the staging warning and the \
                 dirty-buffer refusal apply to lines, and refusals keep Visual"
  =
  with_env (fun env ->
    two_files env;
    (* Unsaved text in the editor's a.txt; the diff of the unstaged section. *)
    let t = run env (run env (create env) "ix<Esc> vx") "<Tab>" in
    print_diff t;
    let t = run env t "7jVjj" in
    let t = run env t "s" in
    report env t;
    visual t;
    [%expect
      {|
       0|diff --git a/a.txt b/a.txt
       1|index 4cb29ea..ddc897f 100644
       2|--- a/a.txt
       3|+++ b/a.txt
       4|@@ -1,3 +1,3 @@
       5| one
       6|-two
       7|+TWO
       8| three
       9|diff --git a/c.txt b/c.txt
      10|index 558ad60..4e95300 100644
      11|--- a/c.txt
      12|+++ b/c.txt
      13|@@ -1 +1 @@
      14|-sea
      15|+SEA
      notice: Select lines within one file; nothing ran
      Diff: header unstaged; diff (Unstaged())
      visual: Linewise
      |}];
    (* Staging a.txt's lines warns; until its refresh, line actions are busy. *)
    let t = keys env t "k" in
    let t = keys env t "s" in
    report env t;
    visual t;
    let t = keys env t "GVx" in
    report env t;
    visual t;
    [%expect
      {|
      planned: Stage Lines unstaged a.txt #0:2,3
      notice: a.txt has unsaved changes: the saved files were staged, not the buffers
      message: a.txt has unsaved changes: the saved files were staged, not the buffers
      Diff: header unstaged; diff (Unstaged()); mutation "Stage 1 line of a.txt"
      visual: none
      notice: Busy: Stage 1 line of a.txt; nothing ran
      message: a.txt has unsaved changes: the saved files were staged, not the buffers
      Diff: header unstaged; diff (Unstaged()); mutation "Stage 1 line of a.txt"
      visual: Linewise
      |}];
    (* A discard of c.txt's lines: refused over the dirty buffer, before any
       question. *)
    let t = run env t "" in
    print_diff t;
    let t = run env t "5jVx" in
    report env t;
    visual t;
    status env;
    [%expect
      {|
       0|diff --git a/c.txt b/c.txt
       1|index 558ad60..4e95300 100644
       2|--- a/c.txt
       3|+++ b/c.txt
       4|@@ -1 +1 @@
       5|-sea
       6|+SEA
      planned: Discard Lines unstaged c.txt #0:0
      notice: Discard 1 line of c.txt refused: unsaved changes in a.txt; save or undo them first; nothing ran
      message: Discard 1 line of c.txt refused: unsaved changes in a.txt; save or undo them first; nothing ran
      Diff: header unstaged; diff (Unstaged())
      visual: Linewise
      status: M  a.txt,  M c.txt
      |}])
;;
