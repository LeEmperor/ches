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

type action = | [@@deriving sexp_of]

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

let plan (_ : Repository.t) (_ : snapshot) (action : action)
  : Ches_vcs.Backend.Plan.Decision.t
  =
  match action with
  | _ -> .
;;
