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

let run title steps : Decision.t =
  Run { Ches_vcs.Backend.Plan.title; steps; rewrites_worktree = false }
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
    "%s is conflicted: conflict resolution is not supported yet; resolve it in the \
     editor, then stage it (s) to mark it resolved; nothing ran"
    path
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
  | (Unstage_verb | Discard_verb), Conflicted ->
    Refused "Conflict resolution is not supported yet; nothing ran"
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
  | Conflicted -> Refused (conflicted path)
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
  | Conflicted -> Refused (conflicted path)
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
;;
