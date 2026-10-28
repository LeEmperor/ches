open! Core
open Ches_vcs

module Section = struct
  type t =
    | Conflicted
    | Untracked
    | Unstaged
    | Staged
    | Ignored
  [@@deriving sexp, equal, compare, enumerate]

  let name = function
    | Conflicted -> "conflicted"
    | Untracked -> "untracked"
    | Unstaged -> "unstaged"
    | Staged -> "staged"
    | Ignored -> "ignored"
  ;;

  let id t = Panel.Section_id.of_string (name t)

  let of_id section_id =
    List.find all ~f:(fun t ->
      String.equal (name t) (Panel.Section_id.to_string section_id))
  ;;

  let title = function
    | Conflicted -> "Conflicted"
    | Untracked -> "Untracked files"
    | Unstaged -> "Unstaged changes"
    | Staged -> "Staged changes"
    | Ignored -> "Ignored files"
  ;;
end

let files_panel = Panel.Id.of_string "files"
let branches_panel = Panel.Id.of_string "branches"
let commits_panel = Panel.Id.of_string "commits"
let local_section = Panel.Section_id.of_string "local"
let recent_section = Panel.Section_id.of_string "recent"

type snapshot =
  { repository : Repository.t
  ; refresh : Ches_vcs.Backend.Refresh.t
  ; status : Status.t
  ; branches : Branch_list.Branch.t list
  ; commits : Log.Commit.t list
  ; operations : In_progress.t list
  ; problems : string list
  }
[@@deriving sexp_of]

type item =
  | File of
      { section : Section.t
      ; entry : Status.Entry.t
      }
  | Branch of Branch_list.Branch.t
  | Commit of Log.Commit.t
[@@deriving sexp_of]

type diff_target =
  | Unstaged of string list
  | Staged of string list
  | Untracked of string
  | Conflicted of string list
  | Commit of string
[@@deriving sexp, equal]

let diff_section : diff_target -> Section.t option = function
  | Unstaged _ -> Some Unstaged
  | Staged _ -> Some Staged
  | Untracked _ -> Some Untracked
  | Conflicted _ -> Some Conflicted
  | Commit _ -> None
;;

module Target = struct
  type t =
    | File of
        { section : Section.t
        ; path : string
        }
    | Section of Section.t
    | Hunk of
        { section : Section.t
        ; file : Diff.File.t
        ; hunk : int
        ; selection : Patch.Selection.t
        }
    | Lines of
        { section : Section.t
        ; file : Diff.File.t
        ; hunks : (int * Patch.Selection.t) list
        }
  [@@deriving sexp_of]
end

type action =
  | Stage of Target.t
  | Unstage of Target.t
  | Discard of Target.t
  | Stage_all
  | Unstage_all
  | Finish_commit of
      { kind : Commit.Kind.t
      ; flags : string list
      ; message_file : string
      }
  | Extend of { flags : string list }
  | Fetch
  | Pull of { flags : string list }
  | Push of
      { target : Remote.Push.Target.t
      ; flags : string list
      }
  | Checkout of string
  | Checkout_previous
  | Create_branch of string
  | Abort of Operation.Kind.t
  | Continue of Operation.Kind.t
  | Skip_rebase_commit
  | Merge of
      { branch : string
      ; flags : string list
      }
  | Resolve of
      { path : string
      ; side : Resolution.Side.t
      }
[@@deriving sexp_of]

let name = "git"

module Repository = Repository

module Snapshot = struct
  type t = snapshot [@@deriving sexp_of]
end

module Item = struct
  type t = item [@@deriving sexp_of]
end

module Diff_target = struct
  type t = diff_target [@@deriving sexp, equal]
end

module Action = struct
  type t = action [@@deriving sexp_of]
end

let detect = Repository.detect
let detected = Repository.detected

let refresh (repository : Repository.t) (refresh : Ches_vcs.Backend.Refresh.t)
  : Job.Step.t list
  =
  let cwd = repository.root in
  [ Job.Step.Run (Status.command ~ignored:refresh.ignored ~cwd ())
  ; Run (Branch_list.command ~cwd)
  ; Run (Log.command ~cwd ~limit:refresh.log_limit)
  ]
  @ List.map (In_progress.reads ~git_dir:repository.git_dir) ~f:(fun read ->
    Job.Step.Read_file read)
;;

(* Whether to parse a command's stdout: [Some cut] when it succeeded or was cut at its
   limit (a valid prefix), [None] when it failed. *)
let parsable (result : Exec.Result.t) =
  if Exec.Result.cut_at_limit result
  then Some true
  else if Exec.Result.succeeded result
  then Some false
  else None
;;

let snapshot repository refresh_request (reports : Job.Step_report.t list) =
  let expected = refresh repository refresh_request in
  let steps = List.map reports ~f:(fun (report : Job.Step_report.t) -> report.step) in
  if not (List.equal Job.Step.equal expected steps)
  then
    Or_error.error_s
      [%message
        "git refresh: the report does not match the refresh's steps"
          ~steps:(List.length steps : int)
          ~expected:(List.length expected : int)]
  else (
    match
      List.find reports ~f:(fun (report : Job.Step_report.t) ->
        match report.outcome with
        | Skipped -> true
        | Ran _ | Read _ -> false)
    with
    | Some skipped -> Or_error.error_string (Step_failure.of_report skipped)
    | None ->
      (match reports with
       | { step = Run status_spec; outcome = Ran status_result }
         :: { step = Run branch_spec; outcome = Ran branch_result }
         :: { step = Run log_spec; outcome = Ran log_result }
         :: state_reports ->
         let%bind.Or_error status =
           match parsable status_result with
           | None ->
             Or_error.error_string (Step_failure.of_result status_spec status_result)
           | Some cut ->
             Status.parse ~cut status_result.stdout
             |> Or_error.tag ~tag:(Exec.Spec.to_string_hum status_spec)
         in
         let problems = Queue.create () in
         let parse_or_problem spec (result : Exec.Result.t) parse ~quiet_failure =
           match parsable result with
           | None ->
             if not quiet_failure
             then Queue.enqueue problems (Step_failure.of_result spec result);
             []
           | Some cut ->
             (match parse ~cut result.stdout with
              | Ok values -> values
              | Error error ->
                Queue.enqueue
                  problems
                  (sprintf
                     "%s: %s"
                     (Exec.Spec.to_string_hum spec)
                     (Error.to_string_mach error));
                [])
         in
         let branches =
           parse_or_problem
             branch_spec
             branch_result
             Branch_list.parse
             ~quiet_failure:false
         in
         let commits =
           parse_or_problem
             log_spec
             log_result
             Log.parse
             ~quiet_failure:(Option.is_none status.branch.oid)
         in
         let operations =
           let failed =
             List.filter state_reports ~f:(fun (report : Job.Step_report.t) ->
               not (Job.Step_report.succeeded report))
           in
           if not (List.is_empty failed)
           then (
             List.iter failed ~f:(fun report ->
               Queue.enqueue problems (Step_failure.of_report report));
             [])
           else (
             let outcomes =
               List.filter_map state_reports ~f:(fun (report : Job.Step_report.t) ->
                 match report.step, report.outcome with
                 | Read_file read, Read result -> Some (read, result)
                 | _ -> None)
             in
             match In_progress.parse ~git_dir:repository.git_dir outcomes with
             | Ok operations -> operations
             | Error error ->
               Queue.enqueue problems (Error.to_string_mach error);
               [])
         in
         Ok
           { repository
           ; refresh = refresh_request
           ; status
           ; branches
           ; commits
           ; operations
           ; problems = Queue.to_list problems
           }
       | _ -> Or_error.error_s [%message "git refresh: unexpected step outcomes"]))
;;

let summary (snapshot : snapshot) : Ches_vcs.Backend.Summary.t =
  let branch = snapshot.status.branch in
  let gone =
    List.exists snapshot.branches ~f:(fun (b : Branch_list.Branch.t) ->
      b.current
      &&
      match b.upstream with
      | Some { tracking = Gone; _ } -> true
      | Some _ | None -> false)
  in
  let upstream =
    Option.map branch.upstream ~f:(fun name : Ches_vcs.Backend.Summary.Upstream.t ->
      let ahead, behind =
        if gone then 0, 0 else Option.value branch.ahead_behind ~default:(0, 0)
      in
      { name; ahead; behind; gone })
  in
  { branch = branch.head
  ; revision = Option.map branch.oid ~f:(fun oid -> String.prefix oid 7)
  ; upstream
  ; operations = List.map snapshot.operations ~f:In_progress.describe
  }
;;

(* The Files sections an entry appears in. *)
let sections_of (entry : Status.Entry.t) : Section.t list =
  match entry with
  | Changed { index; worktree; _ } | Renamed_or_copied { index; worktree; _ } ->
    List.filter_opt
      [ (if Status.Change.equal worktree Unmodified then None else Some Section.Unstaged)
      ; (if Status.Change.equal index Unmodified then None else Some Section.Staged)
      ]
  | Unmerged _ -> [ Conflicted ]
  | Untracked _ -> [ Untracked ]
  | Ignored _ -> [ Ignored ]
;;

let files (snapshot : snapshot) : item Panel.t =
  let sections =
    List.filter_map Section.all ~f:(fun section ->
      if Section.equal section Ignored && not snapshot.refresh.ignored
      then None
      else (
        let items =
          List.filter_map snapshot.status.entries ~f:(fun entry ->
            if List.mem (sections_of entry) section ~equal:Section.equal
            then
              Some
                { Panel.Item.key = Status.Entry.path entry
                ; value = File { section; entry }
                }
            else None)
        in
        if List.is_empty items
        then None
        else
          Some
            { Panel.Section.id = Section.id section
            ; title = Section.title section
            ; items
            }))
  in
  { id = files_panel; title = "Files"; sections }
;;

let single_section ~id ~title ~section ~section_title items : item Panel.t =
  { id
  ; title
  ; sections =
      (if List.is_empty items
       then []
       else [ { Panel.Section.id = section; title = section_title; items } ])
  }
;;

let panels (snapshot : snapshot) =
  [ files snapshot
  ; single_section
      ~id:branches_panel
      ~title:"Branches"
      ~section:local_section
      ~section_title:"Local branches"
      (List.map snapshot.branches ~f:(fun (branch : Branch_list.Branch.t) ->
         { Panel.Item.key = branch.name; value = Branch branch }))
  ; single_section
      ~id:commits_panel
      ~title:"Commits"
      ~section:recent_section
      ~section_title:"Recent commits"
      (List.map snapshot.commits ~f:(fun (commit : Log.Commit.t) ->
         { Panel.Item.key = commit.hash; value = (Commit commit : item) }))
  ]
;;

let diff_target (snapshot : snapshot) panel (position : Panel.Position.t) =
  if Panel.Id.equal panel files_panel
  then (
    let entries_of section =
      List.filter snapshot.status.entries ~f:(fun entry ->
        List.mem (sections_of entry) section ~equal:Section.equal)
    in
    match position with
    | Header section_id ->
      (match Section.of_id section_id with
       | None -> None
       | Some section ->
         (match entries_of section with
          | [] -> None
          | entries ->
            (match section with
             | Unstaged -> Some (Unstaged [])
             | Staged -> Some (Staged [])
             | Conflicted -> Some (Conflicted (List.map entries ~f:Status.Entry.path))
             | Untracked | Ignored -> None)))
    | Item { section = section_id; key } ->
      (match Section.of_id section_id with
       | None -> None
       | Some section ->
         (match
            List.find (entries_of section) ~f:(fun entry ->
              String.equal (Status.Entry.path entry) key)
          with
          | None -> None
          | Some entry ->
            (match section, entry with
             | Unstaged, _ -> Some (Unstaged [ key ])
             | Staged, Renamed_or_copied { original; path; _ } ->
               Some (Staged [ original; path ])
             | Staged, _ -> Some (Staged [ key ])
             | Untracked, _ when String.is_suffix key ~suffix:"/" -> None
             | Untracked, _ -> Some (Untracked key)
             | Conflicted, _ -> Some (Conflicted [ key ])
             | Ignored, _ -> None))))
  else if Panel.Id.equal panel commits_panel
  then (
    match position with
    | Item { section; key }
      when Panel.Section_id.equal section recent_section
           && List.exists snapshot.commits ~f:(fun (commit : Log.Commit.t) ->
             String.equal commit.hash key) -> Some (Commit key)
    | Item _ | Header _ -> None)
  else None
;;

let source : diff_target -> Diff_output.Source.t = function
  | Unstaged paths | Conflicted paths -> Worktree { paths }
  | Staged paths -> Index { paths }
  | Untracked path -> Untracked path
  | Commit hash -> Commit hash
;;

let diff (repository : Repository.t) target : Job.Step.t list =
  [ Run (Diff_output.command ~cwd:repository.root (source target)) ]
;;

let parse_diff target limits (reports : Job.Step_report.t list) =
  match reports with
  | [ { step = Run spec; outcome = Ran result } ] ->
    if Exec.Result.cut_at_limit result
    then Diff_output.parse limits ~cut:true result.stdout
    else if Exec.Result.exited_with result (Diff_output.ok_exits (source target))
    then Diff_output.parse limits ~cut:false result.stdout
    else Or_error.error_string (Step_failure.of_result spec result)
  | [ report ] -> Or_error.error_string (Step_failure.of_report report)
  | _ ->
    Or_error.error_s
      [%message "git diff: expected one step report" ~got:(List.length reports : int)]
;;

(* Phase 3 plans: stage, unstage and discard. Every rule and text is in the contract
   comment of backend.mli; [plan] only looks at the snapshot. *)
module Decision = Ches_vcs.Backend.Plan.Decision

type verb =
  | Stage_verb
  | Unstage_verb
  | Discard_verb

let count ?(noun = "file") n = if n = 1 then "1 " ^ noun else sprintf "%d %ss" n noun

let entries_in (snapshot : snapshot) section =
  List.filter snapshot.status.entries ~f:(fun entry ->
    List.mem (sections_of entry) section ~equal:Section.equal)
;;

let find_entry snapshot section key =
  List.find (entries_in snapshot section) ~f:(fun entry ->
    String.equal (Status.Entry.path entry) key)
;;

let unborn (snapshot : snapshot) = Option.is_none snapshot.status.branch.oid

(* An untracked key ending in "/" is a directory git did not descend into: a nested
   repository (status lists every other untracked file by itself). *)
let nested key = String.is_suffix key ~suffix:"/"

let has_submodule : Status.Entry.t -> bool = function
  | Changed { submodule; _ }
  | Renamed_or_copied { submodule; _ }
  | Unmerged { submodule; _ } -> Option.is_some submodule
  | Untracked _ | Ignored _ -> false
;;

let worktree_change : Status.Entry.t -> Status.Change.t = function
  | Changed { worktree; _ } | Renamed_or_copied { worktree; _ } -> worktree
  | Unmerged _ | Untracked _ | Ignored _ -> Unmodified
;;

(* Intent-to-add ([git add -N]): an index entry without content, shown as added in the
   work tree. *)
let intent_to_add entry = Status.Change.equal (worktree_change entry) Added

(* The paths naming an entry's index side: a rename or copy's original, then its path. *)
let index_paths : Status.Entry.t -> string list = function
  | Renamed_or_copied { original; path; _ } -> [ original; path ]
  | entry -> [ Status.Entry.path entry ]
;;

let git ?stdin (repository : Repository.t) args =
  Job.Step.Run (Cli.mutate ?stdin ~cwd:repository.root ("--literal-pathspecs" :: args))
;;

let add repository paths = [ git repository ("add" :: "--all" :: "--" :: paths) ]

let restore_staged repository snapshot paths =
  if unborn snapshot
  then [ git repository ("reset" :: "--quiet" :: "--" :: paths) ]
  else [ git repository ("restore" :: "--staged" :: "--" :: paths) ]
;;

let restore_worktree repository paths =
  [ git repository ("restore" :: "--worktree" :: "--" :: paths) ]
;;

let restore_head repository snapshot paths =
  if unborn snapshot
  then [ git repository ("rm" :: "--force" :: "--quiet" :: "--" :: paths) ]
  else
    [ git
        repository
        ("restore" :: "--source=HEAD" :: "--staged" :: "--worktree" :: "--" :: paths)
    ]
;;

let clean repository paths =
  [ git repository ("clean" :: "--force" :: "--quiet" :: "--" :: paths) ]
;;

(* The check, then the apply: a mutation stops at its first failed step. *)
let apply repository flags patch =
  let args = ("apply" :: flags) @ [ "--whitespace=nowarn" ] in
  [ git ~stdin:(Data patch) repository (args @ [ "--check" ])
  ; git ~stdin:(Data patch) repository args
  ]
;;

let run ?(rewrites_worktree = false) title steps : Decision.t =
  Run { Ches_vcs.Backend.Plan.title; steps; rewrites_worktree }
;;

let confirm ~title ~message plan_title steps : Decision.t =
  Confirm
    { title
    ; message
    ; plan = { Ches_vcs.Backend.Plan.title = plan_title; steps; rewrites_worktree = true }
    }
;;

let refused fmt = ksprintf (fun message : Decision.t -> Refused message) fmt

let conflicted path =
  sprintf
    "%s is conflicted: take a side with x, or resolve it in the editor (Space x), then \
     stage it (s) to mark it resolved; nothing ran"
    path
;;

let conflicted_section =
  "Resolve conflicted files one at a time (x on a file); nothing ran"
;;

let conflicted_hunk =
  "Resolve conflicts in the editor: Enter opens the file at the conflict, Space x u, l, \
   a or b keeps a side; nothing ran"
;;

(* An entry a section or [S]/[U] action leaves out: [label] for the confirmation's "Left
   out:" list, [refusal] when nothing else remains. *)
type left_out =
  { path : string
  ; label : string
  ; refusal : string
  }

let leave entry ~label (refusal : (string -> string, unit, string) format) =
  let path = Status.Entry.path entry in
  Either.Second { path; label; refusal = sprintf refusal path }
;;

(* How each action takes an entry: [First paths], or [Second] when left out. *)
let take_key entry = Either.First [ Status.Entry.path entry ]
let take_index entry = Either.First (index_paths entry)

let stage_untracked entry =
  if nested (Status.Entry.path entry)
  then
    leave
      entry
      ~label:"nested repository"
      "%s is a nested repository: Ches does not stage it; nothing ran"
  else take_key entry
;;

let discard_unstaged entry =
  if has_submodule entry
  then
    leave
      entry
      ~label:"submodule"
      "%s is a submodule: discard is not supported; nothing ran"
  else if intent_to_add entry
  then
    leave
      entry
      ~label:"intent-to-add"
      "%s is intent-to-add (git add -N): discarding would empty it; nothing ran"
  else take_key entry
;;

let discard_untracked entry =
  if nested (Status.Entry.path entry)
  then
    leave
      entry
      ~label:"nested repository"
      "%s is a nested repository: delete it outside Ches; nothing ran"
  else take_key entry
;;

let discard_staged entry =
  if has_submodule entry
  then
    leave
      entry
      ~label:"submodule"
      "%s is a submodule: discard is not supported; nothing ran"
  else if not (Status.Change.equal (worktree_change entry) Unmodified)
  then
    leave
      entry
      ~label:"also has unstaged changes"
      "%s also has unstaged changes: discard or stage them first; nothing ran"
  else take_index entry
;;

(* A section header or [S]/[U]: [make ~n ~paths ~title_suffix ~message_suffix] over the
   [n] entries taken, naming the left-out ones; refused with [empty] when there is no
   entry at all, or with the first left-out entry's refusal when none is taken. *)
let collective entries ~classify ~empty ~make : Decision.t =
  let taken, left = List.partition_map entries ~f:classify in
  match taken, left with
  | [], [] -> Refused empty
  | [], first :: _ -> Refused first.refusal
  | _ :: _, _ ->
    let title_suffix, message_suffix =
      match left with
      | [] -> "", ""
      | _ :: _ ->
        ( sprintf
            " (left out: %s)"
            (String.concat ~sep:", " (List.map left ~f:(fun left -> left.path)))
        , sprintf
            " Left out: %s."
            (String.concat
               ~sep:", "
               (List.map left ~f:(fun left -> sprintf "%s (%s)" left.path left.label))) )
    in
    make ~n:(List.length taken) ~paths:(List.concat taken) ~title_suffix ~message_suffix
;;

let file_plan repository snapshot verb (section : Section.t) key : Decision.t =
  match find_entry snapshot section key with
  | None -> refused "%s is no longer listed; refresh (g r); nothing ran" key
  | Some entry ->
    let single classify ~f =
      match classify entry with
      | Either.First paths -> f paths
      | Second left -> Decision.Refused left.refusal
    in
    (match verb, section with
     | Stage_verb, Unstaged -> run ("Stage " ^ key) (add repository [ key ])
     | Stage_verb, Untracked ->
       single stage_untracked ~f:(fun paths ->
         run ("Stage " ^ key) (add repository paths))
     | Stage_verb, Conflicted ->
       run (sprintf "Mark %s resolved" key) (add repository [ key ])
     | Stage_verb, Staged -> refused "%s is already staged; nothing ran" key
     | (Stage_verb | Discard_verb), Ignored -> refused "%s is ignored; nothing ran" key
     | Unstage_verb, Staged ->
       run ("Unstage " ^ key) (restore_staged repository snapshot (index_paths entry))
     | Unstage_verb, (Unstaged | Untracked | Ignored) ->
       refused "%s is not staged; nothing ran" key
     | (Unstage_verb | Discard_verb), Conflicted -> Refused (conflicted key)
     | Discard_verb, Unstaged ->
       single discard_unstaged ~f:(fun paths ->
         confirm
           ~title:"Discard changes"
           ~message:
             (sprintf
                "Discard the unstaged changes to %s? They are lost; staged changes are \
                 kept."
                key)
           ("Discard unstaged changes to " ^ key)
           (restore_worktree repository paths))
     | Discard_verb, Untracked ->
       single discard_untracked ~f:(fun paths ->
         confirm
           ~title:"Delete untracked file"
           ~message:(sprintf "Delete %s? It is not in git and cannot be recovered." key)
           ("Delete " ^ key)
           (clean repository paths))
     | Discard_verb, Staged ->
       single discard_staged ~f:(fun paths ->
         let message =
           match entry with
           | _ when unborn snapshot ->
             sprintf "Delete %s? It is new and only staged: its content is lost." key
           | Changed { index = Added; _ } | Renamed_or_copied { index = Copied; _ } ->
             sprintf "Delete %s? It is new and only staged: its content is lost." key
           | Renamed_or_copied { original; _ } ->
             sprintf
               "Undo the rename of %s to %s? %s is deleted with its staged changes and \
                %s is restored from HEAD."
               original
               key
               key
               original
           | Changed { index = Deleted; _ } ->
             sprintf "Restore %s from HEAD? Its staged deletion is undone." key
           | _ ->
             sprintf
               "Discard the staged changes to %s? They are lost: it returns to HEAD in \
                the index and the work tree."
               key
         in
         confirm
           ~title:"Discard changes"
           ~message
           ("Discard staged changes to " ^ key)
           (restore_head repository snapshot paths)))
;;

let section_plan repository snapshot verb (section : Section.t) : Decision.t =
  let collective =
    collective (entries_in snapshot section) ~empty:"Nothing here; nothing ran"
  in
  match verb, section with
  | Stage_verb, Unstaged ->
    collective ~classify:take_key ~make:(fun ~n ~paths ~title_suffix ~message_suffix:_ ->
      run
        (sprintf "Stage unstaged changes (%s)%s" (count n) title_suffix)
        (add repository paths))
  | Stage_verb, Untracked ->
    collective
      ~classify:stage_untracked
      ~make:(fun ~n ~paths ~title_suffix ~message_suffix:_ ->
        run
          (sprintf "Stage untracked files (%s)%s" (count n) title_suffix)
          (add repository paths))
  | Stage_verb, Conflicted ->
    collective ~classify:take_key ~make:(fun ~n ~paths ~title_suffix ~message_suffix:_ ->
      run (sprintf "Mark %s resolved%s" (count n) title_suffix) (add repository paths))
  | Stage_verb, Staged -> Refused "Already staged; nothing ran"
  | Stage_verb, Ignored -> Refused "Ignored files are not staged; nothing ran"
  | Unstage_verb, Staged ->
    collective
      ~classify:take_index
      ~make:(fun ~n ~paths ~title_suffix ~message_suffix:_ ->
        run
          (sprintf "Unstage staged changes (%s)%s" (count n) title_suffix)
          (restore_staged repository snapshot paths))
  | Unstage_verb, (Unstaged | Untracked | Ignored) ->
    Refused "Nothing staged here; nothing ran"
  | (Unstage_verb | Discard_verb), Conflicted -> Refused conflicted_section
  | Discard_verb, Unstaged ->
    collective
      ~classify:discard_unstaged
      ~make:(fun ~n ~paths ~title_suffix ~message_suffix ->
        confirm
          ~title:"Discard changes"
          ~message:
            (sprintf
               "Discard the unstaged changes to %s? They are lost; staged changes are \
                kept.%s"
               (count n)
               message_suffix)
          (sprintf "Discard unstaged changes (%s)%s" (count n) title_suffix)
          (restore_worktree repository paths))
  | Discard_verb, Untracked ->
    collective
      ~classify:discard_untracked
      ~make:(fun ~n ~paths ~title_suffix ~message_suffix ->
        confirm
          ~title:"Delete untracked files"
          ~message:
            (sprintf
               "Delete %s? They are not in git and cannot be recovered.%s"
               (count ~noun:"untracked file" n)
               message_suffix)
          (sprintf "Delete untracked files (%s)%s" (count n) title_suffix)
          (clean repository paths))
  | Discard_verb, Staged ->
    collective
      ~classify:discard_staged
      ~make:(fun ~n ~paths ~title_suffix ~message_suffix ->
        confirm
          ~title:"Discard changes"
          ~message:
            (sprintf
               "Discard the staged changes to %s? They are lost: the files return to \
                HEAD in the index and the work tree (new files are deleted).%s"
               (count n)
               message_suffix)
          (sprintf "Discard staged changes (%s)%s" (count n) title_suffix)
          (restore_head repository snapshot paths))
  | Discard_verb, Ignored -> Refused "Ignored files are not discarded; nothing ran"
;;

let hunk_plan
  repository
  snapshot
  verb
  (section : Section.t)
  (file : Diff.File.t)
  ~hunk
  selection
  : Decision.t
  =
  let path = Diff.File.path file in
  match section with
  | Conflicted -> Refused conflicted_hunk
  | Untracked | Ignored ->
    (* An untracked file's diff is one hunk: the whole file. *)
    file_plan repository snapshot verb section path
  | Unstaged | Staged ->
    let reverse =
      match verb with
      | Stage_verb -> false
      | Unstage_verb | Discard_verb -> true
    in
    (match Patch.hunk file ~hunk selection ~reverse with
     | Error error -> Refused (Error.to_string_hum error)
     | Ok patch ->
       (match find_entry snapshot section path with
        | None -> refused "%s is no longer listed; refresh (g r); nothing ran" path
        | Some entry ->
          let which =
            sprintf "hunk %d/%d of %s" (hunk + 1) (List.length file.hunks) path
          in
          (match verb, section with
           | Stage_verb, Unstaged ->
             run ("Stage " ^ which) (apply repository [ "--cached" ] patch)
           | Stage_verb, _ -> refused "%s is already staged; nothing ran" path
           | Unstage_verb, Staged ->
             run ("Unstage " ^ which) (apply repository [ "--cached"; "--reverse" ] patch)
           | Unstage_verb, _ -> refused "%s is not staged; nothing ran" path
           | Discard_verb, Unstaged ->
             (match discard_unstaged entry with
              | Either.Second left -> Refused left.refusal
              | First _ ->
                confirm
                  ~title:"Discard hunk"
                  ~message:(sprintf "Discard %s? Its unstaged lines are lost." which)
                  ("Discard " ^ which)
                  (apply repository [ "--reverse" ] patch))
           | Discard_verb, _ ->
             (match discard_staged entry with
              | Either.Second left -> Refused left.refusal
              | First _ ->
                confirm
                  ~title:"Discard hunk"
                  ~message:
                    (sprintf
                       "Discard staged %s? It is removed from the index and the work \
                        tree and lost."
                       which)
                  ("Discard staged " ^ which)
                  (apply repository [ "--index"; "--reverse" ] patch)))))
;;

let lines_plan
  repository
  snapshot
  verb
  (section : Section.t)
  (file : Diff.File.t)
  selections
  : Decision.t
  =
  let path = Diff.File.path file in
  let reverse =
    match verb with
    | Stage_verb -> false
    | Unstage_verb | Discard_verb -> true
  in
  match section with
  | Conflicted -> Refused conflicted_hunk
  | Untracked ->
    (match verb with
     | Unstage_verb -> refused "%s is not staged; nothing ran" path
     | Stage_verb | Discard_verb ->
       Refused "Stage the whole untracked file first (s on its row); nothing ran")
  | Ignored -> file_plan repository snapshot verb section path
  | Unstaged | Staged ->
    (match Patch.changes file selections with
     | Error error -> Refused (Error.to_string_hum error)
     | Ok 0 -> Refused "No changes selected; nothing ran"
     | Ok n ->
       (match find_entry snapshot section path, Patch.hunks file selections ~reverse with
        | None, _ -> refused "%s is no longer listed; refresh (g r); nothing ran" path
        | Some _, Error error -> Refused (Error.to_string_hum error)
        | Some entry, Ok patch ->
          let lines = count ~noun:"line" n in
          (match verb, section with
           | Stage_verb, Unstaged ->
             run
               (sprintf "Stage %s of %s" lines path)
               (apply repository [ "--cached" ] patch)
           | Stage_verb, _ -> refused "%s is already staged; nothing ran" path
           | Unstage_verb, Staged ->
             run
               (sprintf "Unstage %s of %s" lines path)
               (apply repository [ "--cached"; "--reverse" ] patch)
           | Unstage_verb, _ -> refused "%s is not staged; nothing ran" path
           | Discard_verb, Unstaged ->
             (match discard_unstaged entry with
              | Either.Second left -> Refused left.refusal
              | First _ ->
                confirm
                  ~title:"Discard lines"
                  ~message:
                    (if n = 1
                     then
                       sprintf "Discard 1 line of %s? Its unstaged change is lost." path
                     else
                       sprintf
                         "Discard %s of %s? Their unstaged changes are lost."
                         lines
                         path)
                  (sprintf "Discard %s of %s" lines path)
                  (apply repository [ "--reverse" ] patch))
           | Discard_verb, _ ->
             (match discard_staged entry with
              | Either.Second left -> Refused left.refusal
              | First _ ->
                let lines = count ~noun:"staged line" n in
                confirm
                  ~title:"Discard lines"
                  ~message:
                    (if n = 1
                     then
                       sprintf
                         "Discard 1 staged line of %s? Its change is removed from the \
                          index and the work tree and lost."
                         path
                     else
                       sprintf
                         "Discard %s of %s? Their changes are removed from the index and \
                          the work tree and lost."
                         lines
                         path)
                  (sprintf "Discard %s of %s" lines path)
                  (apply repository [ "--index"; "--reverse" ] patch)))))
;;

(* Commit steps name no paths, so no [--literal-pathspecs]. *)
let commit_step (repository : Repository.t) args =
  Job.Step.Run (Cli.mutate ~cwd:repository.root args)
;;

(* The given switches in {!Commit.flags} order (the refusal rejected unknown ones). *)
let commit_flags given =
  List.filter Commit.flags ~f:(fun flag -> List.mem given flag ~equal:String.equal)
;;

(* Phase 6: remotes and branches. One step per plan, no paths; the texts are in the
   contract comment of backend.mli. *)
let network_step (repository : Repository.t) args =
  Job.Step.Run (Cli.network ~cwd:repository.root args)
;;

let unknown_flag ~verb ~known given =
  List.find given ~f:(fun flag -> not (List.mem known flag ~equal:String.equal))
  |> Option.map ~f:(fun flag -> sprintf "Unknown %s switch %s; nothing ran" verb flag)
;;

(* [known] restricted to the given switches: the popup's order whatever the caller's. *)
let ordered ~known given =
  List.filter known ~f:(fun flag -> List.mem given flag ~equal:String.equal)
;;

let detached_refusal = "HEAD is detached: check out a branch first; nothing ran"

(* The first operation in progress, bisect aside. *)
let in_progress_refusal (snapshot : snapshot) =
  List.find snapshot.operations ~f:(function
    | Bisect -> false
    | _ -> true)
  |> Option.map ~f:(fun operation ->
    sprintf
      "%s in progress: finish or abort it first; nothing ran"
      (In_progress.describe operation))
;;

let conflicted_refusal (snapshot : snapshot) =
  Option.some_if
    (List.exists snapshot.status.entries ~f:(function
      | Unmerged _ -> true
      | _ -> false))
    "Resolve the conflicted files first (s marks one resolved); nothing ran"
;;

(* An operation in progress, then conflicted files: what checkout and the previous branch
   refuse. *)
let local_refusal snapshot =
  Option.first_some (in_progress_refusal snapshot) (conflicted_refusal snapshot)
;;

(* The current branch's upstream as the branch list has it (remote and merge ref). *)
let current_upstream (snapshot : snapshot) =
  List.find snapshot.branches ~f:(fun branch -> branch.current)
  |> Option.bind ~f:(fun (branch : Branch_list.Branch.t) -> branch.upstream)
;;

let pull_plan repository (snapshot : snapshot) flags : Decision.t =
  let { Status.Branch.head; upstream; _ } = snapshot.status.branch in
  (* In progress before detached: a stopped rebase detaches HEAD. *)
  let early =
    Option.first_some
      (unknown_flag ~verb:"pull" ~known:Remote.Pull.flags flags)
      (in_progress_refusal snapshot)
  in
  match early, head, upstream with
  | Some message, _, _ -> Refused message
  | None, None, _ -> Refused detached_refusal
  | None, Some branch, None ->
    refused "%s has no upstream: push it with P u first; nothing ran" branch
  | None, Some _, Some upstream ->
    (match current_upstream snapshot, conflicted_refusal snapshot with
     | Some { tracking = Gone; _ }, _ ->
       refused "The upstream %s is gone; nothing ran" upstream
     | _, Some message -> Refused message
     | _, None ->
       if List.mem flags "--rebase" ~equal:String.equal
       then
         run
           ~rewrites_worktree:true
           (sprintf "Pull from %s (rebase)" upstream)
           [ network_step repository [ "pull"; "--progress"; "--rebase" ] ]
       else
         run
           ~rewrites_worktree:true
           ("Pull from " ^ upstream)
           [ network_step repository [ "pull"; "--progress"; "--ff-only"; "--no-rebase" ]
           ])
;;

let push_plan repository (snapshot : snapshot) (target : Remote.Push.Target.t) flags
  : Decision.t
  =
  let { Status.Branch.head; upstream; _ } = snapshot.status.branch in
  let known = Remote.Push.flags in
  let early =
    Option.first_some
      (unknown_flag ~verb:"push" ~known flags)
      (in_progress_refusal snapshot)
  in
  match early, head with
  | Some message, _ -> Refused message
  | None, None -> Refused detached_refusal
  | None, Some _ when unborn snapshot -> Refused "There is no commit yet; nothing ran"
  | None, Some branch ->
    let flags = ordered ~known flags in
    let source = "refs/heads/" ^ branch in
    let destination =
      match target, upstream, current_upstream snapshot with
      | Upstream, None, _ ->
        Error
          (sprintf
             "%s has no upstream: P u pushes it to origin/%s and sets it; nothing ran"
             branch
             branch)
      | Upstream, Some _, None ->
        Error "The branch list could not be read; refresh (g r); nothing ran"
      | Upstream, Some upstream, Some { remote; merge; _ } ->
        Ok
          ( upstream
          , ("push" :: "--progress" :: flags)
            @ [ "--end-of-options"; remote; sprintf "%s:%s" source merge ] )
      | Set_upstream, _, _ ->
        Ok
          ( "origin/" ^ branch
          , ("push" :: "--progress" :: "--set-upstream" :: flags)
            @ [ "--end-of-options"; "origin"; sprintf "%s:%s" source source ] )
    in
    (match destination with
     | Error message -> Refused message
     | Ok (dest, args) ->
       let steps = [ network_step repository args ] in
       if List.mem flags "--force-with-lease" ~equal:String.equal
       then
         Confirm
           { title = "Force push"
           ; message =
               sprintf
                 "Force-push %s to %s? Commits on %s that %s does not contain are lost. \
                  git refuses if %s moved since the last fetch."
                 branch
                 dest
                 dest
                 branch
                 dest
           ; plan =
               { title = sprintf "Force-push %s to %s" branch dest
               ; steps
               ; rewrites_worktree = false
               }
           }
       else run (sprintf "Push %s to %s" branch dest) steps)
;;

let checkout_plan repository (snapshot : snapshot) name : Decision.t =
  match
    List.find snapshot.branches ~f:(fun (branch : Branch_list.Branch.t) ->
      String.equal branch.name name)
  with
  | None -> refused "%s is no longer listed; refresh (g r); nothing ran" name
  | Some { current = true; _ } -> refused "Already on %s; nothing ran" name
  | Some _ ->
    (match local_refusal snapshot with
     | Some message -> Refused message
     | None ->
       run
         ~rewrites_worktree:true
         ("Check out " ^ name)
         [ commit_step repository [ "switch"; "--end-of-options"; name ] ])
;;

let create_branch_plan repository (snapshot : snapshot) name : Decision.t =
  if unborn snapshot
  then Refused "There is no commit yet: commit before branching; nothing ran"
  else (
    let existing =
      List.map snapshot.branches ~f:(fun (branch : Branch_list.Branch.t) -> branch.name)
    in
    match in_progress_refusal snapshot, Branch_name.refusal ~existing name with
    | Some message, _ -> Refused message
    | None, Some message -> Refused (message ^ "; nothing ran")
    | None, None ->
      run
        ("Create branch " ^ name)
        [ commit_step repository [ "switch"; "--create"; name ] ])
;;

let abort_plan repository (snapshot : snapshot) (operation : Operation.Kind.t)
  : Decision.t
  =
  (* The subcommand is the noun: [rebase --abort], [merge --abort]. *)
  let noun, message =
    match operation with
    | Rebase ->
      ( "rebase"
      , "Abort the rebase? The branch returns to where it was before the rebase; commits \
         and conflict resolutions made during it are lost." )
    | Merge ->
      ( "merge"
      , "Abort the merge? Its changes and your conflict resolutions are lost; HEAD stays \
         where it is." )
  in
  if not (Operation.in_progress snapshot.operations operation)
  then refused "No %s in progress; nothing ran" noun
  else (
    let title = "Abort " ^ noun in
    confirm ~title ~message title [ commit_step repository [ noun; "--abort" ] ])
;;

(* Phase 7: merges, rebases and conflicts; the texts are in the contract comment of
   backend.mli. *)

(* A step git may answer by starting an editor: [true] keeps the prepared message (the
   runner forces it for every child as well). *)
let editor_step (repository : Repository.t) args =
  let spec = Cli.mutate ~cwd:repository.root args in
  Job.Step.Run { spec with env = spec.env @ [ "GIT_EDITOR", "true" ] }
;;

let noun : Operation.Kind.t -> string = function
  | Rebase -> "rebase"
  | Merge -> "merge"
;;

let not_in_progress (snapshot : snapshot) kind =
  Option.some_if
    (not (Operation.in_progress snapshot.operations kind))
    (sprintf "No %s in progress; nothing ran" (noun kind))
;;

let continue_plan repository (snapshot : snapshot) (kind : Operation.Kind.t) : Decision.t =
  match
    Option.first_some (not_in_progress snapshot kind) (conflicted_refusal snapshot)
  with
  | Some message -> Refused message
  | None ->
    (match kind with
     | Rebase ->
       run
         ~rewrites_worktree:true
         "Continue rebase"
         [ editor_step repository [ "rebase"; "--continue" ] ]
     | Merge ->
       run
         ~rewrites_worktree:true
         "Commit merge"
         [ editor_step repository [ "commit"; "--no-edit"; "--cleanup=strip" ] ])
;;

let merge_plan repository (snapshot : snapshot) ~branch flags : Decision.t =
  let known = Operation.merge_flags in
  let listed =
    match
      List.find snapshot.branches ~f:(fun (b : Branch_list.Branch.t) ->
        String.equal b.name branch)
    with
    | None -> Some (sprintf "%s is no longer listed; refresh (g r); nothing ran" branch)
    | Some { current = true; _ } ->
      Some (sprintf "Cannot merge %s into itself; nothing ran" branch)
    | Some _ -> None
  in
  (* The first that applies, in the contract's order. *)
  let refusal =
    List.find_map
      ~f:Fn.id
      [ unknown_flag ~verb:"merge" ~known flags
      ; Option.some_if (unborn snapshot) "There is no commit yet; nothing ran"
      ; in_progress_refusal snapshot
      ; conflicted_refusal snapshot
      ; listed
      ]
  in
  match refusal with
  | Some message -> Refused message
  | None ->
    let flags = ordered ~known flags in
    let suffix =
      List.map flags ~f:(function
        | "--no-ff" -> " (no fast-forward)"
        | "--ff-only" -> " (fast-forward only)"
        | _ -> "")
      |> String.concat
    in
    run
      ~rewrites_worktree:true
      (sprintf "Merge %s%s" branch suffix)
      [ commit_step
          repository
          (("merge" :: "--no-edit" :: flags) @ [ "--end-of-options"; branch ])
      ]
;;

let resolve_plan repository (snapshot : snapshot) ~path (side : Resolution.Side.t)
  : Decision.t
  =
  match
    List.find_map snapshot.status.entries ~f:(function
      | Unmerged { conflict; path = p; _ } when String.equal p path -> Some conflict
      | _ -> None)
  with
  | None -> refused "%s is not conflicted; nothing ran" path
  | Some conflict ->
    let title = "Resolve " ^ path in
    let ours, theirs = Resolution.labels snapshot.operations in
    (* [checkout --ours] (or [--theirs]) then [add]; [rm] when that side deleted it. *)
    let take ~name ~flag ~label =
      let label = sprintf "%s (%s)" name label in
      if Resolution.has_file conflict side
      then
        confirm
          ~title
          ~message:
            (sprintf
               "Take %s for %s? The other side's changes and any edits to the file are \
                lost; it is marked resolved."
               label
               path)
          (sprintf "Take %s for %s" name path)
          (git repository [ "checkout"; flag; "--"; path ] :: add repository [ path ])
      else
        confirm
          ~title
          ~message:
            (sprintf
               "Resolve %s by deleting it, as %s did? Any edits to the file are lost."
               path
               label)
          (sprintf "Delete %s (resolved)" path)
          [ git repository [ "rm"; "--quiet"; "--"; path ] ]
    in
    (match side with
     | Markers ->
       (match conflict with
        | Both_modified | Both_added ->
          confirm
            ~title
            ~message:
              (sprintf
                 "Restore the conflict markers in %s? Edits to the file are lost."
                 path)
            ("Restore conflict markers in " ^ path)
            [ git repository [ "checkout"; "--merge"; "--"; path ] ]
        | Both_deleted | Added_by_us | Deleted_by_them | Added_by_them | Deleted_by_us ->
          refused
            "%s has no conflict markers to restore (%s); nothing ran"
            path
            (Status.Conflict.to_string_hum conflict))
     | Ours -> take ~name:"ours" ~flag:"--ours" ~label:ours
     | Theirs -> take ~name:"theirs" ~flag:"--theirs" ~label:theirs)
;;

let plan (repository : Repository.t) (snapshot : snapshot) (action : action) : Decision.t =
  let target verb : Target.t -> Decision.t = function
    | File { section; path } -> file_plan repository snapshot verb section path
    | Section section -> section_plan repository snapshot verb section
    | Hunk { section; file; hunk; selection = Whole } ->
      hunk_plan repository snapshot verb section file ~hunk Whole
    | Hunk { section; file; hunk; selection = Lines _ as selection } ->
      lines_plan repository snapshot verb section file [ hunk, selection ]
    | Lines { section; file; hunks } ->
      lines_plan repository snapshot verb section file hunks
  in
  match action with
  | Stage t -> target Stage_verb t
  | Unstage t -> target Unstage_verb t
  | Discard t -> target Discard_verb t
  | Stage_all ->
    (* Conflicted entries are marked resolved one by one, deliberately ([s]). *)
    let entries =
      List.filter snapshot.status.entries ~f:(fun entry ->
        List.exists (sections_of entry) ~f:(function
          | Unstaged | Untracked -> true
          | Conflicted | Staged | Ignored -> false))
    in
    collective
      entries
      ~classify:(fun (entry : Status.Entry.t) ->
        match entry with
        | Untracked _ -> stage_untracked entry
        | _ -> take_key entry)
      ~empty:"Nothing to stage; nothing ran"
      ~make:(fun ~n ~paths ~title_suffix ~message_suffix:_ ->
        run
          (sprintf "Stage all changes (%s)%s" (count n) title_suffix)
          (add repository paths))
  | Unstage_all ->
    collective
      (entries_in snapshot Staged)
      ~classify:take_index
      ~empty:"Nothing staged; nothing ran"
      ~make:(fun ~n ~paths ~title_suffix ~message_suffix:_ ->
        run
          (sprintf "Unstage all changes (%s)%s" (count n) title_suffix)
          (restore_staged repository snapshot paths))
  | Finish_commit { kind; flags; message_file } ->
    (match Commit.refusal snapshot.status (Commit.Choice.Message { kind; flags }) with
     | Some message -> Refused message
     | None ->
       let amend, title =
         match kind with
         | Commit.Kind.Commit -> [], "Commit"
         | Amend -> [ "--amend" ], "Amend HEAD"
       in
       run
         title
         [ commit_step
             repository
             ([ "-c"; "core.commentChar=#"; "commit"; "--cleanup=strip" ]
              @ amend
              @ commit_flags flags
              @ [ "-F"; message_file ])
         ])
  | Extend { flags } ->
    (match Commit.refusal snapshot.status (Commit.Choice.Extend { flags }) with
     | Some message -> Refused message
     | None ->
       run
         "Extend HEAD"
         [ commit_step
             repository
             ([ "commit"; "--amend"; "--no-edit" ] @ commit_flags flags)
         ])
  | Fetch -> run "Fetch" [ network_step repository [ "fetch"; "--progress"; "--prune" ] ]
  | Pull { flags } -> pull_plan repository snapshot flags
  | Push { target; flags } -> push_plan repository snapshot target flags
  | Checkout name -> checkout_plan repository snapshot name
  | Checkout_previous ->
    (match local_refusal snapshot with
     | Some message -> Refused message
     | None ->
       run
         ~rewrites_worktree:true
         "Check out the previous branch"
         [ commit_step repository [ "switch"; "-" ] ])
  | Create_branch name -> create_branch_plan repository snapshot name
  | Abort operation -> abort_plan repository snapshot operation
  | Continue kind -> continue_plan repository snapshot kind
  | Skip_rebase_commit ->
    (match not_in_progress snapshot Rebase with
     | Some message -> Refused message
     | None ->
       confirm
         ~title:"Skip commit"
         ~message:
           "Skip the commit being applied? Its changes are left out of the rebased \
            branch."
         "Skip commit"
         [ editor_step repository [ "rebase"; "--skip" ] ])
  | Merge { branch; flags } -> merge_plan repository snapshot ~branch flags
  | Resolve { path; side } -> resolve_plan repository snapshot ~path side
;;
