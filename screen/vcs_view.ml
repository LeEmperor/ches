(* The VCS view (phase 2: read-only; phase 3: stage, unstage, discard): see
   vcs_view.mli. The diff panel's text, its per-line open targets and positions are
   [Vcs_diff_text]'s; the command plans are the backend's ([plan]). *)

open! Core
open Ches_vcs
module Git = Ches_vcs_git
module B = Git.Backend
module Key = Ches_input.Key
module Text_view = Ches_tile.Text_view
module Navigation = Ches_tile.Navigation
module Local_command = Ches_tile.Local_command
module Content_key = Ches_tile.Content_key

let id = Ches_tile.View_id.of_string "vcs"

let spec =
  { (Ches_tile.Spec.read_only_text id ~title:"VCS") with role = Major; accepts_tab = true }
;;

module Focus = struct
  type t =
    | Files
    | Branches
    | Commits
    | Diff
  [@@deriving sexp_of, equal, enumerate]

  let panel = function
    | Files -> Some B.files_panel
    | Branches -> Some B.branches_panel
    | Commits -> Some B.commits_panel
    | Diff -> None
  ;;

  let lists = [ Files; Branches; Commits ]

  let number = function
    | Files -> "1"
    | Branches -> "2"
    | Commits -> "3"
    | Diff -> "0"
  ;;
end

module Repository_state = struct
  type t =
    | Unknown
    | Detecting
    | Found of Git.Repository.t
    | Not_a_repository of { cwd : string }
    | No_work_tree of
        { cwd : string
        ; message : string
        }
    | Failed of string
  [@@deriving sexp_of]
end

module Diff_state = struct
  type t =
    | Empty
    | No_diff
    | Loading of B.diff_target
    | Loaded of B.diff_target * Diff.t
    | Failed of B.diff_target * string
  [@@deriving sexp_of]

  let target = function
    | Empty | No_diff -> None
    | Loading target | Loaded (target, _) | Failed (target, _) -> Some target
  ;;
end

module Log_entry = struct
  type t =
    { job : Job.Id.t
    ; command : string
    ; status : string option
    ; output : string list
    ; stale : bool
    }
  [@@deriving sexp_of]
end

module Layout = struct
  module Mode = struct
    type t =
      | Side_by_side
      | Stacked
      | Single
    [@@deriving sexp_of, equal]
  end

  type t =
    { mode : Mode.t
    ; lists : Geometry.Rect.t option
    ; diff : Geometry.Rect.t option
    ; log : Geometry.Rect.t option
    }
  [@@deriving sexp_of, equal]

  let side_by_side_width = 80
  let stacked_rows = 16
  let log_rows = 12

  let compute ~width ~rows ~focus ~log =
    let width = Int.max 0 width
    and rows = Int.max 0 rows in
    let rect x y width height = { Geometry.Rect.x; y; width; height } in
    let log, main =
      if log && rows >= log_rows
      then (
        let height = Int.max 4 (rows / 3) in
        Some (rect 0 (rows - height) width height), rows - height)
      else None, rows
    in
    if width >= side_by_side_width
    then (
      let lists = Int.clamp_exn (width * 2 / 5) ~min:30 ~max:60 in
      { mode = Side_by_side
      ; lists = Some (rect 0 0 lists main)
      ; diff = Some (rect (lists + 1) 0 (width - lists - 1) main)
      ; log
      })
    else if main >= stacked_rows
    then (
      let top = main / 2 in
      { mode = Stacked
      ; lists = Some (rect 0 0 width top)
      ; diff = Some (rect 0 (top + 1) width (main - top - 1))
      ; log
      })
    else if Focus.equal focus Diff
    then { mode = Single; lists = None; diff = Some (rect 0 0 width main); log }
    else { mode = Single; lists = Some (rect 0 0 width main); diff = None; log }
  ;;
end

(* Why a job was issued, and what its report is parsed with. *)
module Purpose = struct
  type t =
    | Detect
    | Refresh of Git.Repository.t
    | Diff of B.diff_target
    | Mutate (** A plan's steps; see [Mutation]. *)
  [@@deriving sexp_of]

  let lane = function
    | Detect -> Some "detect"
    | Refresh _ -> Some "refresh"
    | Diff _ -> Some "diff"
    | Mutate -> None
  ;;
end

(* Where the diff cursor goes after a hunk action: hunk [hunk] of the file [path] in
   the next [Loaded] diff of [target]. *)
module Anchor = struct
  type t =
    { target : B.diff_target
    ; path : string
    ; hunk : int
    }
  [@@deriving sexp_of]
end

(* The view's mutation, from its submission until the refresh after its report. *)
module Mutation = struct
  type t =
    { job : Job.Id.t
    ; title : string
    ; root : string (** Reconciled after a work-tree rewrite. *)
    ; rewrites_worktree : bool
    ; anchor : Anchor.t option
    ; settling : bool (** Finished: waiting for the refresh after it. *)
    }
  [@@deriving sexp_of]
end

(* A list panel's cursor (selection identity and folds) and its first visible row. *)
module List_state = struct
  type t =
    { cursor : Panel.Cursor.t
    ; top : int
    }
  [@@deriving sexp_of]

  let empty = { cursor = Panel.Cursor.empty; top = 0 }
end

(* A log entry and the job step it is for ([-1]: a snapshot problem). *)
module Record = struct
  type t =
    { entry : Log_entry.t
    ; step : int
    }
  [@@deriving sexp_of]
end

let log_limit = 200

type planner =
  Git.Repository.t
  -> Git.Backend.snapshot
  -> Git.Backend.action
  -> Backend.Plan.Decision.t

type t =
  { cwd : string
  ; stamps : Stamps.t
  ; repository : Repository_state.t
  ; snapshot : B.snapshot option
  ; panels : B.item Panel.t list
  ; files : List_state.t
  ; branches : List_state.t
  ; commits : List_state.t
  ; focus : Focus.t
  ; list_focus : Focus.t
  ; refresh_error : string option
  ; diff : Diff_state.t
  ; diff_text : Vcs_diff_text.t
  ; diff_shown : B.diff_target option (** The target [diff_text] shows. *)
  ; diff_view : Text_view.t
  ; diff_area : int * int (** The diff text's width and rows, as last fitted. *)
  ; log_visible : bool
  ; log : Record.t list (** Newest first. *)
  ; in_flight : Purpose.t Job.Id.Map.t
  ; plan : (planner[@sexp.opaque])
  ; mutation : Mutation.t option
  ; anchor : Anchor.t option (** Applied to the next [Loaded] diff of its target. *)
  }
[@@deriving sexp_of]

let text_view_of text = Text_view.create ~cell_width:Cell_map.width (Vcs_diff_text.text text)

let create ?(plan = B.plan) ~cwd () =
  let diff_text = Vcs_diff_text.of_message "" in
  { cwd
  ; stamps = Stamps.create ()
  ; repository = Unknown
  ; snapshot = None
  ; panels = []
  ; files = List_state.empty
  ; branches = List_state.empty
  ; commits = List_state.empty
  ; focus = Files
  ; list_focus = Files
  ; refresh_error = None
  ; diff = Empty
  ; diff_text
  ; diff_shown = None
  ; diff_view = text_view_of diff_text
  ; diff_area = 1, 1
  ; log_visible = false
  ; log = []
  ; in_flight = Job.Id.Map.empty
  ; plan
  ; mutation = None
  ; anchor = None
  }
;;

let cwd t = t.cwd
let repository t = t.repository
let snapshot t = t.snapshot
let panels t = t.panels
let refresh_error t = t.refresh_error
let focus t = t.focus
let list_focus t = t.list_focus
let diff t = t.diff
let log_visible t = t.log_visible
let log t = List.rev_map t.log ~f:(fun record -> record.entry)
let stamps t = t.stamps
let mutation t = Option.map t.mutation ~f:(fun mutation -> mutation.title)

let loading t =
  Map.existsi t.in_flight ~f:(fun ~key ~data ->
    match (data : Purpose.t) with
    | Detect | Refresh _ -> Stamps.is_current t.stamps ?lane:(Purpose.lane data) key
    | Diff _ | Mutate -> false)
;;

(* Whether the panels are drawn (and their keys work): a repository was found, or is
   being detected again with the last snapshot still drawn. *)
let loaded t =
  match t.repository with
  | Found _ -> true
  | Detecting -> Option.is_some t.snapshot
  | Unknown | Not_a_repository _ | No_work_tree _ | Failed _ -> false
;;

let text_view t =
  if Focus.equal t.focus Diff && loaded t then Some t.diff_view else None
;;

let list_state t : Focus.t -> List_state.t = function
  | Files -> t.files
  | Branches -> t.branches
  | Commits -> t.commits
  | Diff -> List_state.empty
;;

let set_list_state t (focus : Focus.t) state =
  match focus with
  | Files -> { t with files = state }
  | Branches -> { t with branches = state }
  | Commits -> { t with commits = state }
  | Diff -> t
;;

let cursor t focus = (list_state t focus).cursor

let empty_panel id : B.item Panel.t = { id; title = ""; sections = [] }

let find_panel panels id =
  List.find panels ~f:(fun (panel : _ Panel.t) -> Panel.Id.equal panel.id id)
;;

let panel t focus =
  Option.map (Focus.panel focus) ~f:(fun id ->
    Option.value (find_panel t.panels id) ~default:(empty_panel id))
;;

let rows_of t focus =
  match panel t focus with
  | None -> []
  | Some panel -> Panel.Cursor.rows (cursor t focus) panel
;;

let selected t focus = (cursor t focus).selected

let selected_index t focus =
  match selected t focus with
  | None -> None
  | Some position ->
    Option.map
      (List.findi (rows_of t focus) ~f:(fun _ row -> Panel.Position.equal row position))
      ~f:fst
;;

let selected_item t focus =
  match panel t focus, selected t focus with
  | Some panel, Some position -> Panel.find panel position
  | _ -> None
;;

let one_line text =
  String.split_lines text
  |> List.map ~f:String.strip
  |> List.filter ~f:(Fn.non String.is_empty)
  |> String.concat ~sep:" "
;;

let root t =
  match t.snapshot, t.repository with
  | Some snapshot, _ -> Some (Git.Repository.root snapshot.repository)
  | None, Found repository -> Some (Git.Repository.root repository)
  | None, _ -> None
;;

(* {2 Display text} *)

let change_word : Git.Status.Change.t -> string = function
  | Unmodified -> "unmodified"
  | Modified -> "modified"
  | Type_changed -> "typechange"
  | Added -> "new file"
  | Deleted -> "deleted"
  | Renamed -> "renamed"
  | Copied -> "copied"
  | Updated_unmerged -> "unmerged"
;;

let ahead_behind ~ahead ~behind =
  match ahead, behind with
  | 0, 0 -> "up to date"
  | ahead, 0 -> sprintf "ahead %d" ahead
  | 0, behind -> sprintf "behind %d" behind
  | ahead, behind -> sprintf "ahead %d, behind %d" ahead behind
;;

let item_text : B.item -> string = function
  | File { section; entry } ->
    let submodule = function
      | None -> ""
      | Some _ -> " (submodule)"
    in
    (match section, entry with
     | Conflicted, Unmerged { conflict; path; submodule = sub } ->
       sprintf "%-15s %s%s" (Git.Status.Conflict.to_string_hum conflict) path (submodule sub)
     | Staged, Changed { index; path; submodule = sub; _ } ->
       sprintf "%-10s %s%s" (change_word index) path (submodule sub)
     | Staged, Renamed_or_copied { index; path; original; submodule = sub; _ } ->
       sprintf "%-10s %s -> %s%s" (change_word index) original path (submodule sub)
     | ( Unstaged
       , ( Changed { worktree; path; submodule = sub; _ }
         | Renamed_or_copied { worktree; path; submodule = sub; _ } ) ) ->
       sprintf "%-10s %s%s" (change_word worktree) path (submodule sub)
     | _, entry -> Git.Status.Entry.path entry)
  | Branch { name; current; upstream; subject; _ } ->
    let upstream =
      match upstream with
      | None -> ""
      | Some { name; tracking; refname = _ } ->
        (match tracking with
         | In_sync -> sprintf " [%s]" name
         | Ahead_behind { ahead; behind } ->
           sprintf " [%s: %s]" name (ahead_behind ~ahead ~behind)
         | Gone -> sprintf " [%s: gone]" name)
    in
    sprintf "%s %s%s  %s" (if current then "*" else " ") name upstream subject
  | Commit commit -> sprintf "%s %s" (Git.Log.Commit.short_hash commit) commit.subject
;;

(* What [y] copies: a path, a branch name, an abbreviated hash. *)
let item_name : B.item Panel.Item.t -> string = function
  | { value = File _; key } -> key
  | { value = Branch branch; _ } -> branch.name
  | { value = Commit commit; _ } -> Git.Log.Commit.short_hash commit
;;

let target_title : B.diff_target -> string = function
  | Unstaged [] -> "Unstaged changes"
  | Unstaged paths -> "Unstaged: " ^ String.concat ~sep:", " paths
  | Staged [] -> "Staged changes"
  | Staged [ original; path ] -> sprintf "Staged: %s -> %s" original path
  | Staged paths -> "Staged: " ^ String.concat ~sep:", " paths
  | Untracked path -> "Untracked: " ^ path
  | Conflicted paths -> "Conflicted: " ^ String.concat ~sep:", " paths
  | Commit hash -> "Commit " ^ String.prefix hash 7
;;

let head_label (summary : Backend.Summary.t) =
  match summary.branch, summary.revision with
  | Some branch, _ -> branch
  | None, Some revision -> "detached at " ^ revision
  | None, None -> "detached"
;;

let title t =
  let repository =
    match t.repository with
    | Found repository -> Some repository
    | Detecting -> Option.map t.snapshot ~f:(fun snapshot -> snapshot.repository)
    | Unknown | Not_a_repository _ | No_work_tree _ | Failed _ -> None
  in
  match t.repository, repository with
  | Not_a_repository _, _ -> "VCS: not a repository"
  | No_work_tree _, _ -> "VCS: no work tree"
  | Failed _, _ -> "VCS: error"
  | (Unknown | Detecting | Found _), None -> "VCS"
  | (Unknown | Detecting | Found _), Some repository ->
    let name = Filename.basename (Git.Repository.root repository) in
    (match t.snapshot with
     | Some snapshot
       when Git.Repository.equal snapshot.repository repository ->
       sprintf "VCS: %s (%s)" name (head_label (B.summary snapshot))
     | Some _ | None -> "VCS: " ^ name)
;;

(* The head summary rows above the panels. *)
let summary_rows t : (Style.t * string) list =
  let loading = loading t in
  let head =
    match t.snapshot with
    | None -> [ Style.Status, if loading then "Loading..." else "Nothing loaded yet" ]
    | Some snapshot ->
      let summary = B.summary snapshot in
      let head =
        match summary.branch, summary.revision with
        | Some branch, Some revision -> sprintf "Head: %s %s" branch revision
        | Some branch, None -> sprintf "Head: %s (no commits yet)" branch
        | None, Some revision -> sprintf "Head: detached at %s" revision
        | None, None -> "Head: detached"
      in
      let upstream =
        match summary.upstream with
        | None -> []
        | Some { name; gone = true; _ } ->
          [ Style.Warning, sprintf "Upstream: %s (gone)" name ]
        | Some { name; ahead; behind; gone = false } ->
          [ Style.Status, sprintf "Upstream: %s, %s" name (ahead_behind ~ahead ~behind) ]
      in
      let problems =
        match List.length snapshot.problems with
        | 0 -> []
        | n ->
          [ ( Style.Warning
            , sprintf "%d problem%s reading the repository (@: log)" n
                (if n = 1 then "" else "s") )
          ]
      in
      ((Style.Status, head ^ if loading then "  (refreshing)" else "") :: upstream)
      @ List.map summary.operations ~f:(fun operation -> Style.Warning, operation)
      @ problems
  in
  head
  @ Option.value_map t.refresh_error ~default:[] ~f:(fun error ->
    [ Style.Error, "Refresh failed: " ^ error ])
;;

(* {2 Lists column geometry} *)

type plan =
  { summary : int (** Summary rows shown. *)
  ; gaps : bool
  (** One blank row after the summary (when shown), between panels, and at the
      column's bottom. *)
  ; bodies : (Focus.t * int) list (** Each shown panel's body rows, below its title. *)
  }

(* The lists column's rows, [rows] tall. With room, all three panels show: the ones
   not followed get at most a quarter of the body rows each (as many as they have
   rows), the followed one the rest. Gaps cost the panels nothing: three panels have
   them only with the gaps' rows to spare beyond the 9 they need without them.
   Otherwise only the followed panel shows, with gaps while it keeps at least 3 body
   rows. *)
let lists_plan t ~rows =
  let summary = Int.min (List.length (summary_rows t)) (Int.max 0 (rows - 4)) in
  let available = rows - summary in
  let summary_gap = if summary > 0 then 1 else 0 in
  (* After the summary, between the three panels, and at the bottom. *)
  let three_gaps = summary_gap + 3 in
  if available >= 9
  then (
    let gaps = available >= 9 + three_gaps in
    let body = available - 3 - if gaps then three_gaps else 0 in
    let share = Int.max 1 (body / 4) in
    let others =
      List.filter Focus.lists ~f:(fun focus -> not (Focus.equal focus t.list_focus))
      |> List.map ~f:(fun focus -> focus, Int.min share (List.length (rows_of t focus)))
    in
    let used = List.sum (module Int) others ~f:snd in
    { summary
    ; gaps
    ; bodies =
        List.map Focus.lists ~f:(fun focus ->
          ( focus
          , match List.Assoc.find others focus ~equal:Focus.equal with
            | Some body -> body
            | None -> body - used ))
    })
  else (
    (* After the summary and at the bottom. *)
    let body = available - 1 - (summary_gap + 1) in
    if body >= 3
    then { summary; gaps = true; bodies = [ t.list_focus, body ] }
    else { summary; gaps = false; bodies = [ t.list_focus, Int.max 0 (available - 1) ] })
;;

let body_rows t ~rows focus =
  List.Assoc.find (lists_plan t ~rows).bodies focus ~equal:Focus.equal
;;

let fit_top ~top ~index ~body ~count =
  if body <= 0
  then top
  else (
    let top = Int.max (Int.min top index) (index - body + 1) in
    Int.clamp_exn top ~min:0 ~max:(Int.max 0 (count - body)))
;;

let fit_list t focus ~body =
  let state = list_state t focus in
  let count = List.length (rows_of t focus) in
  let index = Option.value (selected_index t focus) ~default:0 in
  set_list_state t focus { state with top = fit_top ~top:state.top ~index ~body ~count }
;;

let layout t ~rows ~width =
  Layout.compute ~width ~rows ~focus:t.focus ~log:t.log_visible
;;

(* Blank columns on each side of the diff's title and text, in a diff part [width]
   wide: none below 10 columns. *)
let diff_pad width = if width >= 10 then 1 else 0

(* Where the diff text is drawn: the diff part (else the whole viewport) below its
   title row, inside its padding. *)
let diff_text_rect t ~rows ~width =
  let (rect : Geometry.Rect.t) =
    Option.value
      (layout t ~rows ~width).diff
      ~default:{ Geometry.Rect.x = 0; y = 0; width; height = rows }
  in
  let pad = diff_pad rect.width in
  { Geometry.Rect.x = rect.x + pad
  ; y = rect.y + 1
  ; width = Int.max 0 (rect.width - (2 * pad))
  ; height = Int.max 0 (rect.height - 1)
  }
;;

(* The diff text's width and rows in the viewport. *)
let diff_area t ~rows ~width =
  let rect = diff_text_rect t ~rows ~width in
  Int.max 1 rect.width, Int.max 1 rect.height
;;

let fit t ~rows ~width =
  let layout = layout t ~rows ~width in
  let t =
    match layout.lists with
    | None -> t
    | Some rect ->
      List.fold (lists_plan t ~rows:rect.height).bodies ~init:t ~f:(fun t (focus, body) ->
        fit_list t focus ~body)
  in
  let width, rows = diff_area t ~rows ~width in
  { t with diff_view = Text_view.fit t.diff_view ~width ~rows; diff_area = width, rows }
;;

let end_visual t =
  match Text_view.escape t.diff_view with
  | None -> t
  | Some action ->
    let width, rows = t.diff_area in
    { t with diff_view = fst (Text_view.perform t.diff_view ~width ~rows action) }
;;

let leave t = end_visual t

(* {2 The command log} *)

let add_record t record = { t with log = List.take (record :: t.log) log_limit }

let has_record t ~job ~step =
  List.exists t.log ~f:(fun record ->
    record.step = step && Job.Id.equal record.entry.job job)
;;

let update_record t ~job ~step ~f =
  { t with
    log =
      List.map t.log ~f:(fun record ->
        if record.step = step && Job.Id.equal record.entry.job job
        then { record with entry = f record.entry }
        else record)
  }
;;

let stderr_tail (result : Exec.Result.t) =
  if Exec.Result.succeeded result
  then []
  else (
    let lines = String.split_lines result.stderr |> List.filter ~f:(Fn.non String.is_empty) in
    List.drop lines (List.length lines - 5))
;;

(* Record each command step of a finished report: the status and a failed command's
   stderr tail, on the entry its [Started] made (or a new one). *)
let log_report t (report : Job.Report.t) ~stale =
  List.foldi report.steps ~init:t ~f:(fun step t (step_report : Job.Step_report.t) ->
    match step_report.step, step_report.outcome with
    | Read_file _, _ | Run _, Read _ -> t
    | Run spec, Ran result ->
      let status = Some (Exec.Result.status_hum result)
      and output = stderr_tail result in
      if has_record t ~job:report.id ~step
      then
        update_record t ~job:report.id ~step ~f:(fun entry ->
          { entry with status; output; stale })
      else
        add_record
          t
          { step
          ; entry =
              { job = report.id
              ; command = Exec.Spec.to_string_hum spec
              ; status
              ; output
              ; stale
              }
          }
    | Run _, Skipped ->
      update_record t ~job:report.id ~step ~f:(fun entry ->
        { entry with status = Some "skipped"; stale })
  )
;;

(* A snapshot's problems, except those that only repeat a failed command already
   logged with its status and stderr. *)
let log_problems t (report : Job.Report.t) (snapshot : B.snapshot) =
  let failed =
    List.filter_map report.steps ~f:(fun (step_report : Job.Step_report.t) ->
      match step_report.step, step_report.outcome with
      | Run spec, Ran result when not (Exec.Result.succeeded result) ->
        Some (Exec.Spec.to_string_hum spec ^ ":")
      | _ -> None)
  in
  List.fold snapshot.problems ~init:t ~f:(fun t problem ->
    if List.exists failed ~f:(fun prefix -> String.is_prefix problem ~prefix)
    then t
    else
      add_record
        t
        { step = -1
        ; entry =
            { job = report.id
            ; command = problem
            ; status = Some "problem"
            ; output = []
            ; stale = false
            }
        })
;;

(* {2 Jobs} *)

let set_diff_text t ~shown text =
  let same = Option.equal B.equal_diff_target shown t.diff_shown && Option.is_some shown in
  let diff_view =
    if same
    then fst (Text_view.update t.diff_view (Vcs_diff_text.text text))
    else if String.equal (Vcs_diff_text.text text) (Text_view.text t.diff_view)
    then t.diff_view
    else text_view_of text
  in
  { t with diff_text = text; diff_shown = shown; diff_view }
;;

let issue t (purpose : Purpose.t) steps =
  let lane = Purpose.lane purpose in
  let stamps, id = Stamps.issue ?lane t.stamps in
  let t = { t with stamps } in
  match Job.create ~id ?lane steps with
  | Ok job -> { t with in_flight = Map.set t.in_flight ~key:id ~data:purpose }, [ job ]
  | Error error ->
    let message = one_line (Error.to_string_hum error) in
    (match purpose with
     | Detect -> { t with repository = Failed message }, []
     | Refresh _ -> { t with refresh_error = Some message }, []
     | Diff target ->
       ( set_diff_text
           { t with diff = Failed (target, message) }
           ~shown:(Some target)
           (Vcs_diff_text.of_message ("Diff failed: " ^ message))
       , [] )
     | Mutate -> t, [])
;;

(* The diff for the followed list's selection: fetched when its target changes, or
   always with [force] (after a refresh). *)
let request_diff ?(force = false) t =
  let desired =
    match t.snapshot, Focus.panel t.list_focus, selected t t.list_focus with
    | Some snapshot, Some panel, Some position ->
      (match B.diff_target snapshot panel position with
       | None -> `No_diff
       | Some target -> `Target (snapshot.repository, target))
    | _ -> `Empty
  in
  match desired with
  | `Empty ->
    ( set_diff_text
        { t with diff = Empty; anchor = None }
        ~shown:None
        (Vcs_diff_text.of_message "")
    , [] )
  | `No_diff ->
    ( set_diff_text
        { t with diff = No_diff; anchor = None }
        ~shown:None
        (Vcs_diff_text.of_message "No diff for this row")
    , [] )
  | `Target (repository, target) ->
    if (not force)
       && Option.equal B.equal_diff_target (Diff_state.target t.diff) (Some target)
    then t, []
    else issue { t with diff = Loading target } (Diff target) (B.diff repository target)
;;

let clear_snapshot t =
  { (set_diff_text
       { t with diff = Empty }
       ~shown:None
       (Vcs_diff_text.of_message ""))
    with
    snapshot = None
  ; panels = []
  ; files = List_state.empty
  ; branches = List_state.empty
  ; commits = List_state.empty
  ; refresh_error = None
  ; focus = (if Focus.equal t.focus Diff then t.list_focus else t.focus)
  }
;;

(* A new generation: everything in flight becomes stale. *)
let detect t =
  let t = end_visual { t with stamps = Stamps.invalidate t.stamps; repository = Detecting } in
  issue t Detect (B.detect ~cwd:t.cwd)
;;

let refresh t =
  match t.repository with
  | Found repository ->
    issue t (Refresh repository) (B.refresh repository Backend.Refresh.default)
  | Unknown | Detecting | Not_a_repository _ | No_work_tree _ | Failed _ -> detect t
;;

let apply_snapshot t (snapshot : B.snapshot) =
  let current = B.panels snapshot in
  let reconcile t focus =
    match Focus.panel focus with
    | None -> t
    | Some id ->
      let now = Option.value (find_panel current id) ~default:(empty_panel id) in
      let before = Option.value (find_panel t.panels id) ~default:now in
      let state = list_state t focus in
      set_list_state
        t
        focus
        { state with
          cursor = Panel.Cursor.reconcile state.cursor ~previous:before ~current:now
        }
  in
  let t = List.fold Focus.lists ~init:t ~f:reconcile in
  request_diff
    ~force:true
    { t with snapshot = Some snapshot; panels = current; refresh_error = None }
;;

let detected t (report : Job.Report.t) =
  match B.detected ~cwd:t.cwd report.steps with
  | Found repository ->
    let t =
      match t.snapshot with
      | Some snapshot when not (Git.Repository.equal snapshot.repository repository) ->
        clear_snapshot t
      | Some _ | None -> t
    in
    refresh { t with repository = Found repository }
  | Not_a_repository { cwd } ->
    { (clear_snapshot t) with repository = Not_a_repository { cwd } }, []
  | No_work_tree { cwd; message } ->
    { (clear_snapshot t) with repository = No_work_tree { cwd; message } }, []
  | Failed message -> { (end_visual t) with repository = Failed message }, []
;;

(* A settling mutation ends with the current refresh's report, whatever its fate,
   or when no repository is left to refresh. *)
let end_settled_mutation t ~(purpose : Purpose.t) ~current =
  match t.mutation, purpose, t.repository with
  | Some { settling = true; _ }, Refresh _, _ when current -> { t with mutation = None }
  | Some { settling = true; _ }, Detect, (Not_a_repository _ | No_work_tree _ | Failed _) ->
    { t with mutation = None }
  | _ -> t
;;

(* The cursor's offset for [anchor] in a diff just laid out: the [@@] line of hunk
   [anchor.hunk] of its file, else the file's last hunk, else its first line, else
   the text's first line. *)
let anchor_offset text (diff : Diff.t) (anchor : Anchor.t) =
  match
    List.findi diff.files ~f:(fun _ file -> String.equal (Diff.File.path file) anchor.path)
  with
  | None -> 0
  | Some (file, (found : Diff.File.t)) ->
    let last = List.length found.hunks - 1 in
    let hunk =
      if last < 0
      then None
      else Vcs_diff_text.start_of text ~file ~hunk:(Some (Int.min anchor.hunk last))
    in
    Option.first_some hunk (Vcs_diff_text.start_of text ~file ~hunk:None)
    |> Option.value ~default:0
;;

let finished t (report : Job.Report.t) =
  match Map.find t.in_flight report.id with
  | None -> t, []
  | Some purpose ->
    let t = { t with in_flight = Map.remove t.in_flight report.id } in
    let current = Stamps.accepts t.stamps report in
    let used = current && not report.cancelled in
    (match purpose with
     | Detect | Refresh _ ->
       let t = log_report t report ~stale:(not used) in
       let anchor =
         match t.mutation with
         | Some { settling = true; anchor; _ } when current -> anchor
         | Some _ | None -> None
       in
       let t, jobs =
         match purpose, used with
         | _, false when current && report.cancelled ->
           (* The current detection or refresh will not answer: say so instead of
              loading forever. *)
           (match purpose with
            | Detect ->
              { t with repository = Failed "repository detection was cancelled" }, []
            | Refresh _ | Diff _ | Mutate ->
              { t with refresh_error = Some "refresh cancelled" }, [])
         | _, false -> t, []
         | Detect, true -> detected t report
         | Refresh repository, true ->
           (match B.snapshot repository Backend.Refresh.default report.steps with
            | Ok snapshot ->
              apply_snapshot { (log_problems t report snapshot) with anchor } snapshot
            | Error error ->
              { t with refresh_error = Some (one_line (Error.to_string_hum error)) }, [])
         | (Diff _ | Mutate), true -> t, []
       in
       end_settled_mutation t ~purpose ~current, jobs
     | Mutate -> t, []
     | Diff target ->
       let parsed =
         if report.cancelled
         then None
         else Some (B.parse_diff target Diff.Limits.default report.steps)
       in
       (* Only failed diffs reach the log. *)
       let t =
         match parsed with
         | Some (Error _) -> log_report t report ~stale:(not used)
         | Some (Ok _) | None -> t
       in
       if not current
       then t, []
       else (
         let anchor = t.anchor in
         let t = { t with anchor = None } in
         match parsed with
         | None ->
           ( set_diff_text
               { t with diff = Failed (target, "cancelled") }
               ~shown:(Some target)
               (Vcs_diff_text.of_message "Diff cancelled; g r reads it again")
           , [] )
         | Some (Ok diff) ->
           let text = Vcs_diff_text.of_diff diff in
           let t =
             set_diff_text { t with diff = Loaded (target, diff) } ~shown:(Some target) text
           in
           (match anchor with
            | Some anchor when B.equal_diff_target anchor.target target ->
              let offset = anchor_offset text diff anchor in
              { t with diff_view = Text_view.jump t.diff_view offset }, []
            | Some _ | None -> t, [])
         | Some (Error error) ->
           let message = one_line (Error.to_string_hum error) in
           ( set_diff_text
               { t with diff = Failed (target, message) }
               ~shown:(Some target)
               (Vcs_diff_text.of_message ("Diff failed: " ^ message))
           , [] )))
;;

let event t (event : Event.t) =
  match event with
  | Output _ -> t, []
  | Started { job; step; spec } ->
    (match Map.find t.in_flight job with
     | None | Some (Diff _) -> t, []
     | Some purpose ->
       ( add_record
           t
           { step
           ; entry =
               { job
               ; command = Exec.Spec.to_string_hum spec
               ; status = None
               ; output = []
               ; stale =
                   not (Stamps.is_current t.stamps ?lane:(Purpose.lane purpose) job)
               }
           }
       , [] ))
  | Finished report -> finished t report
;;

(* {2 Mutations} *)

(* One line for a mutation's failed step: git's first stderr line and the status. *)
let failure_line (step_report : Job.Step_report.t) =
  match step_report.outcome with
  | Ran result ->
    let status = Exec.Result.status_hum result in
    (match
       List.find_map (String.split_lines result.stderr) ~f:(fun line ->
         Option.some_if (not (String.is_empty (String.strip line))) (String.strip line))
     with
     | Some line -> sprintf "%s (%s)" line status
     | None -> status)
  | Skipped -> "cancelled"
  | Read _ -> "a file read failed"
;;

let is_mutation t id =
  match Map.find t.in_flight id with
  | Some Mutate -> true
  | Some (Detect | Refresh _ | Diff _) | None -> false
;;

(* The mutation's report: logged; a failure noticed; open buffers reconciled after a
   work-tree rewrite, whatever the outcome; then a refresh, which ends the mutation
   (a stale report's repository is refreshed too, or its new detection's refresh
   ends it). Returns the jobs, the failure and the roots to reconcile. *)
let mutation_finished t (report : Job.Report.t) =
  let t = { t with in_flight = Map.remove t.in_flight report.id } in
  let t = log_report t report ~stale:(not (Stamps.accepts t.stamps report)) in
  match t.mutation with
  | Some mutation when Job.Id.equal mutation.job report.id ->
    let failure =
      Option.map (Job.Report.first_failure report) ~f:(fun step_report ->
        sprintf "%s failed: %s" mutation.title (failure_line step_report))
    in
    let reconcile = if mutation.rewrites_worktree then [ mutation.root ] else [] in
    let settling = Some { mutation with settling = true } in
    let t, jobs =
      match t.repository with
      | Found _ ->
        let t, jobs = refresh { t with mutation = settling } in
        (* A refresh that could not be issued cannot end it. *)
        (if List.is_empty jobs then { t with mutation = None } else t), jobs
      | Detecting -> { t with mutation = settling }, []
      | Unknown | Not_a_repository _ | No_work_tree _ | Failed _ ->
        { t with mutation = None }, []
    in
    t, jobs, failure, reconcile
  | Some _ | None -> t, [], None, []
;;

(* {2 Actions} *)

(* What [s u x S U] ask for. *)
module Verb = struct
  type t =
    | Stage
    | Unstage
    | Discard
    | Stage_all
    | Unstage_all
  [@@deriving sexp_of]

  let of_key key =
    List.find_map
      [ 's', Stage; 'u', Unstage; 'x', Discard; 'S', Stage_all; 'U', Unstage_all ]
      ~f:(fun (c, verb) -> Option.some_if (Key.equal key (Key.char c)) verb)
  ;;

  (* [S] and [U] need no target. *)
  let targeted = function
    | Stage | Unstage | Discard -> true
    | Stage_all | Unstage_all -> false
  ;;

  let word = function
    | Stage | Stage_all -> "stage"
    | Unstage | Unstage_all -> "unstage"
    | Discard -> "discard"
  ;;

  let action verb (target : B.Target.t) : B.action =
    match verb with
    | Stage -> Stage target
    | Unstage -> Unstage target
    | Discard -> Discard target
    | Stage_all -> Stage_all
    | Unstage_all -> Unstage_all
  ;;
end

(* A plan to run (planned, or confirmed with [y]): its steps go out as one job. *)
module Submission = struct
  type t =
    { plan : Backend.Plan.t
    ; root : string
    ; anchor : Anchor.t option
    }
  [@@deriving sexp_of]
end

type action =
  | Shown
  | Refresh
  | Event of Event.t
  | Focus_list of Focus.t
  | Focus_diff
  | Toggle_diff
  | Back
  | Select
  | Toggle_fold of Panel.Section_id.t
  | Move of Navigation.Motion.t
  | Copy
  | Text of Text_view.Action.t
  | Open_file
  | Toggle_log
  | Leave
  | Act of Verb.t
  | Act_on_lines of Verb.t (** [s u x] in Visual in the diff. *)
  | Submit of Submission.t (** A confirmed plan. *)
  | Next_hunk of
      { forward : bool
      ; count : int
      }
[@@deriving sexp_of]

let is c key = Key.equal key (Key.char c)

(* A count before a key, as {!Text_view} reads it: [1]-[9], then any digits. *)
let split_count (keys : Key.t list) =
  match keys with
  | first :: _ when Option.exists (Key.digit first) ~f:(fun d -> d > 0) ->
    let digits, rest = List.split_while keys ~f:(fun key -> Option.is_some (Key.digit key)) in
    ( Some
        (List.fold digits ~init:0 ~f:(fun n key ->
           Int.min Ches_core.Command.max_count ((n * 10) + Option.value_exn (Key.digit key))))
    , rest )
  | _ -> None, keys
;;

let interpret t (keys : Key.t list) : action Content_key.t =
  let loaded = loaded t in
  match keys with
  | [ g; r ] when is 'g' g && is 'r' r -> Action Refresh
  | [ key ] when is '@' key -> Action Toggle_log
  | [ key ] when is 'q' key -> Action Leave
  | [ key ] when is 'g' key && not loaded -> Prefix
  | _ when not loaded -> Unbound
  | [ Tab ] -> Action Toggle_diff
  | keys when Focus.equal t.focus Diff ->
    (* Digits are the text's count ([10j], [3\]]) or line start here, not panel keys;
       a count before [s u x S U] is dropped, as the text drops it before other keys. *)
    let visual = Option.is_some (Text_view.visual t.diff_view) in
    (match keys, split_count keys with
     | [ Enter ], _ -> Action Open_file
     | [ key ], _ when is 'e' key -> Action Open_file
     | _, (_, [ key ]) when Option.is_some (Verb.of_key key) ->
       let verb = Option.value_exn (Verb.of_key key) in
       if visual && Verb.targeted verb
       then Action (Act_on_lines verb)
       else Action (Act verb)
     | _, (count, [ key ]) when (is ']' key || is '[' key) && not visual ->
       Action (Next_hunk { forward = is ']' key; count = Option.value count ~default:1 })
     | keys, _ -> Content_key.map (Text_view.interpret t.diff_view keys) ~f:(fun a -> Text a))
  | [ key ] when is '1' key -> Action (Focus_list Files)
  | [ key ] when is '2' key -> Action (Focus_list Branches)
  | [ key ] when is '3' key -> Action (Focus_list Commits)
  | [ key ] when is '0' key -> Action Focus_diff
  | [ key ] when is 'y' key -> Action Copy
  | [ key ] when Focus.equal t.focus Files && Option.is_some (Verb.of_key key) ->
    Action (Act (Option.value_exn (Verb.of_key key)))
  | [ Enter ] ->
    (match selected t t.focus with
     | Some (Header section) -> Action (Toggle_fold section)
     | Some (Item _) when not (Focus.equal t.focus Branches) -> Action Select
     | Some (Item _) | None -> Unbound)
  | keys -> Content_key.map (Navigation.interpret keys) ~f:(fun m -> Move m)
;;

let escape t =
  if Focus.equal t.focus Diff && loaded t
  then (
    match Text_view.escape t.diff_view with
    | Some action -> Some (Text action)
    | None -> Some Back)
  else None
;;

let under ~dir path =
  String.equal path dir
  || String.is_prefix path ~prefix:(if String.is_suffix dir ~suffix:"/" then dir else dir ^ "/")
;;

let signal t : View_registry.Signal.t -> action option = function
  | Shown -> Some Shown
  | Saved paths ->
    (match t.repository with
     | Found repository ->
       let root = Git.Repository.root repository in
       Option.some_if
         (List.exists paths ~f:(fun path -> under ~dir:root path || under ~dir:t.cwd path))
         Refresh
     | Unknown | Detecting | Not_a_repository _ | No_work_tree _ | Failed _ -> None)
  | Job (Output _) -> None
  | Job event -> Some (Event event)
;;

let move t motion ~rows ~width =
  let focus = t.focus in
  match panel t focus, (layout t ~rows ~width).lists with
  | Some panel, Some rect ->
    let positions = rows_of t focus in
    let count = List.length positions in
    if count = 0
    then t
    else (
      let body = Option.value (body_rows t ~rows:rect.height focus) ~default:1 in
      let index = Option.value (selected_index t focus) ~default:0 in
      let half = Int.max 1 (body / 2) in
      let index =
        Int.clamp_exn
          ~min:0
          ~max:(count - 1)
          (match (motion : Navigation.Motion.t) with
           | Down -> index + 1
           | Up -> index - 1
           | Half_down -> index + half
           | Half_up -> index - half
           | First -> 0
           | Last -> count - 1)
      in
      let state = list_state t focus in
      let t =
        set_list_state
          t
          focus
          { state with
            cursor = Panel.Cursor.select state.cursor panel (List.nth_exn positions index)
          }
      in
      fit_list t focus ~body)
  | _ -> t
;;

let open_target t =
  match Vcs_diff_text.line_at t.diff_text (Text_view.cursor t.diff_view), root t with
  | Some { target = Some { path = Some path; line; display = _ }; _ }, Some root ->
    let path = if String.is_suffix root ~suffix:"/" then root ^ path else root ^ "/" ^ path in
    `Open { View_registry.Location.path; line }
  | Some { target = Some { path = None; display; _ }; _ }, _ ->
    `Notice (sprintf "%s was deleted: nothing to open" display)
  | _ -> `Notice "No file at the cursor"
;;

(* What [s u x] act on: the Files panel's selected row, or the diff's line at the
   cursor; [S U] on everything. [Error] is the notice instead. The anchor is where
   the diff cursor goes after a hunk action. *)
let action_of t (verb : Verb.t) : (B.action * Anchor.t option, string) Result.t =
  let act target = Ok (Verb.action verb target, None) in
  let section id =
    Result.of_option (B.Section.of_id id) ~error:"No change at the cursor"
  in
  match verb with
  | Stage_all -> Ok (Stage_all, None)
  | Unstage_all -> Ok (Unstage_all, None)
  | Stage | Unstage | Discard ->
    (match t.focus with
    | Files ->
      (match selected t Files with
       | Some (Header id) -> Result.bind (section id) ~f:(fun section -> act (Section section))
       | Some (Item { section = id; key }) ->
         Result.bind (section id) ~f:(fun section -> act (File { section; path = key }))
       | None -> Error "Nothing selected")
    | Branches | Commits -> Error "Nothing selected"
    | Diff ->
      (match t.diff with
       | Loading _ -> Error "The diff is still loading"
       | Empty | No_diff | Failed _ -> Error "No change at the cursor"
       | Loaded (target, diff) ->
         (match B.diff_section target with
          | None -> Error (sprintf "Nothing to %s here: a commit's diff" (Verb.word verb))
          | Some section ->
            (match
               Option.bind
                 (Vcs_diff_text.position_at t.diff_text (Text_view.cursor t.diff_view))
                 ~f:(fun position ->
                   Option.map (List.nth diff.files position.file) ~f:(fun file ->
                     position, file))
             with
             | None -> Error "No change at the cursor"
             | Some ({ hunk = None; _ }, file) ->
               act (File { section; path = Diff.File.path file })
             | Some ({ hunk = Some hunk; _ }, file) ->
               let path = Diff.File.path file in
               Ok
                 ( Verb.action verb (Hunk { section; file; hunk; selection = Whole })
                 , Some { Anchor.target; path; hunk } )))))
;;

(* What Visual [s u x] act on: the lines of one file the diff's selection touches
   (phase 4), anchored on the first touched hunk. [Error] is the notice instead. *)
let lines_action_of t (verb : Verb.t) : (B.action * Anchor.t option, string) Result.t =
  match t.diff with
  | Loading _ -> Error "The diff is still loading"
  | Empty | No_diff | Failed _ -> Error "No change at the cursor"
  | Loaded (target, diff) ->
    (match B.diff_section target, Text_view.selection t.diff_view with
     | None, _ -> Error (sprintf "Nothing to %s here: a commit's diff" (Verb.word verb))
     | Some _, None -> Error "No changes selected; nothing ran"
     | Some section, Some (start, stop) ->
       (match Vcs_diff_text.span t.diff_text ~start ~stop with
        | Error `Several_files -> Error "Select lines within one file; nothing ran"
        | Ok None -> Error "No changes selected; nothing ran"
        | Ok (Some span) ->
          (match List.nth diff.files span.file with
           | None -> Error "No change at the cursor"
           | Some file ->
             let path = Diff.File.path file in
             let hunks =
               List.map span.hunks ~f:(fun (hunk, lines) ->
                 hunk, Git.Patch.Selection.Lines lines)
             in
             Ok
               ( Verb.action verb (Lines { section; file; hunks })
               , Option.map (List.hd span.hunks) ~f:(fun (hunk, _) ->
                   { Anchor.target; path; hunk }) ))))
;;

let join root path =
  if String.is_suffix root ~suffix:"/" then root ^ path else root ^ "/" ^ path
;;

(* The Files keys an action stages (a key ending in "/" covers what is under it);
   [] for an action that does not stage. *)
let staged_keys t (action : B.action) =
  let keys sections =
    match find_panel t.panels B.files_panel with
    | None -> []
    | Some panel ->
      List.concat_map panel.sections ~f:(fun (section : _ Panel.Section.t) ->
        if List.exists sections ~f:(fun s ->
             Panel.Section_id.equal (B.Section.id s) section.id)
        then List.map section.items ~f:(fun item -> item.key)
        else [])
  in
  match action with
  | Stage (File { path; _ }) -> [ path ]
  | Stage (Hunk { file; _ } | Lines { file; _ }) -> [ Diff.File.path file ]
  | Stage (Section section) -> keys [ section ]
  | Stage_all -> keys [ Unstaged; Untracked ]
  | Unstage _ | Discard _ | Unstage_all -> []
;;

(* The warning for staging paths whose buffers have unsaved text. *)
let staging_warning t context ~root action =
  let keys = List.map (staged_keys t action) ~f:(join root) in
  let dirty =
    View_registry.Context.dirty_within context ~root
    |> List.filter ~f:(fun (file : View_registry.Context.File.t) ->
      List.exists keys ~f:(fun key ->
        if String.is_suffix key ~suffix:"/"
        then String.is_prefix file.path ~prefix:key
        else String.equal file.path key))
  in
  match dirty with
  | [] -> None
  | files ->
    Some
      (sprintf
         "%s %s unsaved changes: the saved files were staged, not the buffers"
         (String.concat
            ~sep:", "
            (List.map files ~f:(fun (file : View_registry.Context.File.t) -> file.label)))
         (if List.length files = 1 then "has" else "have"))
;;

(* The refusal of a work-tree rewrite while file buffers within the root are dirty. *)
let dirty_refusal context (submission : Submission.t) =
  if not submission.plan.rewrites_worktree
  then None
  else (
    match View_registry.Context.dirty_within context ~root:submission.root with
    | [] -> None
    | files ->
      Some
        (sprintf
           "%s refused: unsaved changes in %s; save or undo them first; nothing ran"
           submission.plan.title
           (String.concat
              ~sep:", "
              (List.map files ~f:(fun (file : View_registry.Context.File.t) -> file.label)))))
;;

let busy t =
  Option.map t.mutation ~f:(fun mutation -> sprintf "Busy: %s; nothing ran" mutation.title)
;;

(* The plan's steps as one mutation job. [Error] is the failure notice. *)
let submit t (submission : Submission.t) =
  let stamps, id = Stamps.issue t.stamps in
  match Job.create ~id submission.plan.steps with
  | Ok job ->
    Ok
      ( { t with
          stamps
        ; in_flight = Map.set t.in_flight ~key:id ~data:Mutate
        ; mutation =
            Some
              { job = id
              ; title = submission.plan.title
              ; root = submission.root
              ; rewrites_worktree = submission.plan.rewrites_worktree
              ; anchor = submission.anchor
              ; settling = false
              }
        }
      , job )
  | Error error ->
    Error
      (sprintf "%s failed: %s" submission.plan.title (one_line (Error.to_string_hum error)))
;;

(* The next or previous [@@] line, [count] times, stopping at the last or first. *)
let next_hunk t ~forward ~count =
  let starts = Vcs_diff_text.hunk_starts t.diff_text in
  let cursor = Text_view.cursor t.diff_view in
  let text = Text_view.text t.diff_view in
  let line_start offset =
    if offset <= 0
    then 0
    else (
      match String.rindex_from text (offset - 1) '\n' with
      | Some i -> i + 1
      | None -> 0)
  in
  let step offset =
    if forward
    then List.find starts ~f:(fun start -> start > offset)
    else List.find (List.rev starts) ~f:(fun start -> start < line_start offset)
  in
  let rec go offset count =
    if count <= 0
    then offset
    else (
      match step offset with
      | None -> offset
      | Some offset -> go offset (count - 1))
  in
  let target = go cursor count in
  if target = cursor then t else { t with diff_view = Text_view.jump t.diff_view target }
;;

let perform t controller ~context ~rows ~width action =
  let t = fit t ~rows ~width in
  let outcome ?effect ?notice ?(return = false) ?open_file ?(jobs = []) ?reconcile ?ask t =
    ( fit t ~rows ~width
    , View_registry.Outcome.create
        ?effect
        ?notice
        ~return
        ?open_file
        ~jobs
        ?reconcile
        ?ask
        controller )
  in
  let with_jobs (t, jobs) = outcome t ~jobs in
  let run ?warning t submission =
    match dirty_refusal context submission with
    | Some refusal -> outcome t ~notice:(`Post refusal)
    | None ->
      (match submit t submission with
       | Error failure -> outcome t ~notice:(`Post failure)
       | Ok (t, job) ->
         outcome
           (end_visual t)
           ~jobs:[ job ]
           ?notice:(Option.map warning ~f:(fun w -> `Post w)))
  in
  (* Plans the chosen action and runs it or asks; a refusal keeps a Visual selection
     so it can be adjusted, running or asking ends it. *)
  let act t chosen =
    match busy t, t.snapshot with
    | Some busy, _ -> outcome t ~notice:(`Show busy)
    | None, None -> outcome t ~notice:(`Show "Nothing loaded yet")
    | None, Some (snapshot : B.snapshot) ->
      (match chosen t with
       | Error notice -> outcome t ~notice:(`Show notice)
       | Ok (action, anchor) ->
         let root = Git.Repository.root snapshot.repository in
         (match t.plan snapshot.repository snapshot action with
          | Refused message -> outcome t ~notice:(`Show message)
          | Run plan ->
            run t { plan; root; anchor } ?warning:(staging_warning t context ~root action)
          | Confirm { title; message; plan } ->
            let submission = { Submission.plan; root; anchor } in
            (match dirty_refusal context submission with
             | Some refusal -> outcome t ~notice:(`Post refusal)
             | None ->
               outcome
                 (end_visual t)
                 ~ask:
                   (View_registry.Ask.Confirm
                      { title; message; yes = Submit submission; no = None }))))
  in
  match action with
  | Shown -> with_jobs (detect t)
  | Refresh -> with_jobs (refresh t)
  | Event (Finished report) when is_mutation t report.id ->
    let t, jobs, failure, reconcile = mutation_finished t report in
    outcome t ~jobs ~reconcile ?notice:(Option.map failure ~f:(fun f -> `Post f))
  | Event e -> with_jobs (event t e)
  | Act verb -> act t (fun t -> action_of t verb)
  | Act_on_lines verb -> act t (fun t -> lines_action_of t verb)
  | Submit submission ->
    (match busy t with
     | Some busy -> outcome t ~notice:(`Show busy)
     | None -> run t submission)
  | Next_hunk { forward; count } -> outcome (next_hunk t ~forward ~count)
  | Focus_list focus ->
    let t = end_visual t in
    with_jobs (request_diff { t with focus; list_focus = focus })
  | Focus_diff | Select -> outcome { t with focus = Diff }
  | Toggle_diff ->
    if Focus.equal t.focus Diff
    then outcome (end_visual { t with focus = t.list_focus })
    else outcome { t with focus = Diff }
  | Back -> outcome (end_visual { t with focus = t.list_focus })
  | Toggle_fold section ->
    (match panel t t.focus with
     | None -> outcome t
     | Some panel ->
       let state = list_state t t.focus in
       let t =
         set_list_state
           t
           t.focus
           { state with cursor = Panel.Cursor.toggle_fold state.cursor panel section }
       in
       with_jobs (request_diff t))
  | Move motion -> with_jobs (request_diff (move t motion ~rows ~width))
  | Copy ->
    (match selected_item t t.focus with
     | None -> outcome t ~effect:(Text_view.Effect.Notice "nothing to copy")
     | Some item ->
       outcome
         t
         ~effect:
           (Text_view.Effect.Copy
              (Ches_core.Register.Text { text = item_name item; kind = Characterwise })))
  | Text action ->
    let w, h = diff_area t ~rows ~width in
    let diff_view, effect = Text_view.perform t.diff_view ~width:w ~rows:h action in
    outcome { t with diff_view } ?effect
  | Open_file ->
    (match open_target t with
     | `Open location -> outcome t ~open_file:location
     | `Notice text -> outcome t ~notice:(`Show text))
  | Toggle_log -> outcome { t with log_visible = not t.log_visible }
  | Leave -> outcome t ~return:true
;;

let commands t =
  let c name keys description = Local_command.create name ~keys description in
  let k = Key.char in
  let refresh =
    c
      "refresh"
      [ k 'g'; k 'r' ]
      (match t.repository with
       | Found _ -> "Refresh"
       | _ -> "Look for a repository again")
  in
  let always =
    [ refresh
    ; c "toggle-log" [ k '@' ] "Show or hide the command log"
    ; c "leave" [ k 'q' ] "Leave the VCS view"
    ]
  in
  if not (loaded t)
  then always
  else (
    let panels =
      [ c "focus-files" [ k '1' ] "Focus the Files panel"
      ; c "focus-branches" [ k '2' ] "Focus the Branches panel"
      ; c "focus-commits" [ k '3' ] "Focus the Commits panel"
      ]
    in
    let all =
      [ c "stage-all" [ k 'S' ] "Stage all changes (not conflicts)"
      ; c "unstage-all" [ k 'U' ] "Unstage all changes"
      ]
    in
    match t.focus with
    | Diff ->
      let visual = Option.is_some (Text_view.visual t.diff_view) in
      (* [s u x] act on the cursor's hunk, or in Visual on the selected lines, in a
         diff of the work tree or index, not in a commit's diff. *)
      let at_cursor =
        match t.diff with
        | Loaded (target, _) when visual && Option.is_some (B.diff_section target) ->
          [ c "stage" [ k 's' ] "Stage the selected lines (one file)"
          ; c "unstage" [ k 'u' ] "Unstage the selected lines (one file)"
          ; c "discard" [ k 'x' ] "Discard the selected lines (one file); confirmed"
          ]
        | Loaded (target, _) when Option.is_some (B.diff_section target) ->
          [ c "stage" [ k 's' ] "Stage the hunk at the cursor (on a file header: the file)"
          ; c "unstage" [ k 'u' ] "Unstage the hunk at the cursor (or the file)"
          ; c "discard" [ k 'x' ] "Discard the hunk at the cursor (or the file); confirmed"
          ]
        | Empty | No_diff | Loading _ | Loaded _ | Failed _ -> []
      in
      let hunks =
        if visual
        then []
        else
          [ c "next-hunk" [ k ']' ] "Next hunk"
          ; c "previous-hunk" [ k '[' ] "Previous hunk"
          ]
      in
      always
      @ [ c "toggle-diff" [ Tab ] "Back to the list"
        ; c "open-file" [ k 'e' ] "Open the file at the cursor's line"
        ]
      @ at_cursor
      @ all
      @ hunks
      @ Text_view.commands t.diff_view
    | Files | Branches | Commits ->
      let enter =
        match selected t t.focus with
        | Some (Header _) -> [ c "toggle-fold" [ Enter ] "Fold or unfold the section" ]
        | Some (Item _) when not (Focus.equal t.focus Branches) ->
          [ c "select" [ Enter ] "Focus the diff of the selection" ]
        | Some (Item _) | None -> []
      in
      let copy =
        match t.focus with
        | Files -> "Copy the file's path"
        | Branches -> "Copy the branch name"
        | Commits | Diff -> "Copy the abbreviated hash"
      in
      let actions =
        match t.focus with
        | Files ->
          [ c "stage" [ k 's' ] "Stage the file or section (a conflict: mark it resolved)"
          ; c "unstage" [ k 'u' ] "Unstage the file or section"
          ; c "discard" [ k 'x' ] "Discard the file's or section's changes; confirmed"
          ]
          @ all
        | Branches | Commits | Diff -> []
      in
      always
      @ panels
      @ [ c "focus-diff" [ k '0' ] "Focus the diff"
        ; c "toggle-diff" [ Tab ] "Focus the diff"
        ]
      @ enter
      @ actions
      @ [ c "copy" [ k 'y' ] copy ]
      @ Navigation.commands)
;;

(* {2 Rendering} *)

let blank_row width = [ Span.blank Status (Int.max 0 width) ]

(* Exactly [height] rows of [width]. *)
let sized ~width ~height rows =
  List.init (Int.max 0 height) ~f:(fun i ->
    match List.nth rows i with
    | Some row -> row
    | None -> blank_row width)
;;

(* One display row of the diff text in its line's style; Visual as Tile_text draws
   it. *)
let diff_row (row : Text_view.Row.t) ~width ~selected ~style =
  let selection = Style.document ~overlay:Selection () in
  let spans =
    Array.to_list row.glyphs
    |> List.map ~f:(fun (glyph : Cell_map.Glyph.t) ->
      let style : Style.t =
        if selected (row.line_start + glyph.pos)
        then selection
        else (
          match glyph.kind with
          | Plain -> style
          | Tab -> style
          | Escape -> Status_special)
      in
      Span.create style glyph.text ~width:glyph.width)
  in
  let spans = Span.keep_left spans ~n:width ~marker_style:Status_special in
  let used = Span.total_width spans in
  let break =
    if used < width && Option.exists row.break ~f:selected
    then [ Span.blank selection 1 ]
    else []
  in
  Span.merge
    (spans @ break @ [ Span.blank style (Int.max 0 (width - used - List.length break)) ])
;;

let diff_body t ~width ~rows =
  let view = Text_view.fit t.diff_view ~width:(Int.max 1 width) ~rows:(Int.max 1 rows) in
  let selected =
    match Text_view.selection view with
    | Some (start, stop) when Focus.equal t.focus Diff ->
      fun offset -> start <= offset && offset < stop
    | Some _ | None -> fun _ -> false
  in
  Text_view.rows view ~width
  |> Fn.flip List.drop (Text_view.top view)
  |> Fn.flip List.take (Int.max 0 rows)
  |> List.map ~f:(fun (row : Text_view.Row.t) ->
    let style =
      Option.value_map
        (Vcs_diff_text.kind_at_start t.diff_text row.line_start)
        ~default:Style.Status
        ~f:Vcs_diff_text.Kind.style
    in
    diff_row row ~width ~selected ~style)
;;

let panel_title_style t focus : Style.t =
  if Focus.equal t.focus focus then Pending else Title
;;

let diff_part t (rect : Geometry.Rect.t) =
  let state =
    match t.diff with
    | Empty -> "Diff"
    | No_diff -> "Diff: none"
    | Loading target -> sprintf "Diff: %s (loading)" (target_title target)
    | Loaded (target, _) -> "Diff: " ^ target_title target
    | Failed (target, _) -> sprintf "Diff: %s (failed)" (target_title target)
  in
  let pad = diff_pad rect.width in
  let width = rect.width - (2 * pad) in
  let padded row =
    if pad = 0
    then row
    else Span.merge ((Span.blank Status pad :: row) @ [ Span.blank Status pad ])
  in
  List.map
    ~f:padded
    (Tile_text.row (panel_title_style t Diff) ("0 " ^ state) ~width
     :: diff_body t ~width ~rows:(rect.height - 1))
;;

let panel_rows t focus ~width ~body =
  match panel t focus with
  | None -> []
  | Some panel ->
    let state = list_state t focus in
    let positions = Panel.Cursor.rows state.cursor panel in
    let count =
      List.sum (module Int) panel.sections ~f:(fun section -> List.length section.items)
    in
    let title =
      Tile_text.row
        (panel_title_style t focus)
        (sprintf "%s %s (%d)" (Focus.number focus) panel.title count)
        ~width
    in
    let row position =
      let selected =
        Option.exists state.cursor.selected ~f:(Panel.Position.equal position)
      in
      match (position : Panel.Position.t) with
      | Header section_id ->
        (match Panel.find_section panel section_id with
         | None -> Tile_text.item ~selected Status "" ~width
         | Some section ->
           Tile_text.item
             ~selected
             Diff_meta
             (sprintf
                "%s %s (%d)"
                (if Set.mem state.cursor.folded section_id then "+" else "-")
                section.title
                (List.length section.items))
             ~width)
      | Item _ ->
        (match Panel.find panel position with
         | None -> Tile_text.item ~selected Status "" ~width
         | Some item -> Tile_text.item ~selected Status (item_text item.value) ~width)
    in
    let body_rows =
      if count = 0 && body > 0
      then [ Tile_text.row Stale "  (none)" ~width ]
      else List.map (List.take (List.drop positions state.top) body) ~f:row
    in
    title :: sized ~width ~height:body body_rows
;;

let lists_part t (rect : Geometry.Rect.t) =
  let plan = lists_plan t ~rows:rect.height in
  let gap = if plan.gaps then [ blank_row rect.width ] else [] in
  let summary =
    List.take (summary_rows t) plan.summary
    |> List.map ~f:(fun (style, text) -> Tile_text.row style text ~width:rect.width)
  in
  (* The bottom gap is the rows left blank below the last panel. *)
  summary
  @ (if plan.summary > 0 then gap else [])
  @ List.concat
      (List.intersperse
         ~sep:gap
         (List.map plan.bodies ~f:(fun (focus, body) ->
            panel_rows t focus ~width:rect.width ~body)))
;;

let short_command command =
  match
    String.chop_prefix
      command
      ~prefix:(String.concat ~sep:" " ("git" :: Git.Cli.prefix) ^ " ")
  with
  | Some rest -> "git " ^ rest
  | None -> command
;;

let log_part t (rect : Geometry.Rect.t) =
  let width = rect.width in
  let entries = log t in
  let lines =
    List.concat_map entries ~f:(fun (entry : Log_entry.t) ->
      let style : Style.t =
        match entry.status with
        | _ when entry.stale -> Stale
        | None -> Status
        | Some "exit 0" -> Status
        | Some "problem" -> Warning
        | Some _ -> Error
      in
      let status =
        match entry.status with
        | None -> "running"
        | Some status -> status
      in
      Tile_text.row
        style
        (sprintf
           "[%s%s] %s"
           status
           (if entry.stale then ", stale" else "")
           (short_command entry.command))
        ~width
      :: List.map entry.output ~f:(fun line -> Tile_text.row style ("    " ^ line) ~width))
  in
  let body = Int.max 0 (rect.height - 1) in
  Tile_text.row Title (sprintf "@ Command log (%d)" (List.length entries)) ~width
  :: List.drop lines (List.length lines - body)
;;

let message_part t =
  let row (style : Style.t) text = style, text in
  match t.repository with
  | Unknown -> [ row Style.Status "Not opened yet" ]
  | Detecting -> [ row Style.Status (sprintf "Looking for a repository from %s ..." t.cwd) ]
  | Not_a_repository { cwd } ->
    [ row Style.Warning "Not a git repository:"
    ; row Status cwd
    ; row Status ""
    ; row Status "g r looks again; q leaves"
    ]
  | No_work_tree { cwd; message } ->
    [ row Style.Warning "No work tree here:"
    ; row Status cwd
    ; row Status message
    ; row Status ""
    ; row Status "g r looks again; q leaves"
    ]
  | Failed message ->
    [ row Style.Error "Could not read the repository:"
    ; row Status message
    ; row Status ""
    ; row Status "g r retries; @ shows the log"
    ]
  | Found _ -> []
;;

(* Place parts (rectangles and their rows) into [rows] rows of [width] cells. *)
let compose ~width ~rows parts =
  List.init (Int.max 0 rows) ~f:(fun y ->
    let pieces =
      List.filter_map parts ~f:(fun ((rect : Geometry.Rect.t), part_rows) ->
        if rect.width > 0 && rect.y <= y && y < rect.y + rect.height
        then (
          let row =
            match List.nth part_rows (y - rect.y) with
            | Some row -> row
            | None -> blank_row rect.width
          in
          Some (rect.x, rect.width, row))
        else None)
      |> List.sort ~compare:(fun (a, _, _) (b, _, _) -> Int.compare a b)
    in
    let x, spans =
      List.fold pieces ~init:(0, []) ~f:(fun (x, spans) (at, part_width, row) ->
        let gap = if at > x then [ Span.blank Status (at - x) ] else [] in
        Int.max x (at + part_width), spans @ gap @ row)
    in
    Span.merge (spans @ if x < width then [ Span.blank Status (width - x) ] else []))
;;

let render t ~hotkey_hints ~focused:_ ~notice ~pending ~width ~rows : Tile_shell.Content.t =
  let width = Int.max 0 width
  and rows = Int.max 0 rows in
  let t = fit t ~rows ~width in
  let layout = layout t ~rows ~width in
  let log = Option.map layout.log ~f:(fun rect -> rect, log_part t rect) in
  let main_rows = Option.value_map layout.log ~default:rows ~f:(fun rect -> rect.y) in
  let parts =
    if loaded t
    then (
      let lists = Option.map layout.lists ~f:(fun rect -> rect, lists_part t rect) in
      let diff = Option.map layout.diff ~f:(fun rect -> rect, diff_part t rect) in
      let separator =
        match layout.lists, layout.diff with
        | Some lists, Some diff when lists.y = diff.y ->
          let rect = { lists with x = lists.width; width = diff.x - lists.width } in
          Some
            ( rect
            , List.init rect.height ~f:(fun _ -> [ Span.create Border "│" ~width:1 ]) )
        | Some lists, Some diff ->
          let rect = { lists with y = lists.height; height = diff.y - lists.height } in
          Some
            ( rect
            , List.init rect.height ~f:(fun _ ->
                [ Span.create Border (String.concat (List.init width ~f:(fun _ -> "─")))
                    ~width
                ]) )
        | _ -> None
      in
      List.filter_opt [ lists; separator; diff ])
    else
      [ ( { Geometry.Rect.x = 0; y = 0; width; height = main_rows }
        , List.map (message_part t) ~f:(fun (style, text) -> Tile_text.row style text ~width) )
      ]
  in
  let parts = parts @ Option.to_list log in
  let default =
    let hints keys = if hotkey_hints then " | " ^ keys else "" in
    if not (loaded t)
    then (if hotkey_hints then "g r retry, @ log, q leave" else "")
    else (
      match t.focus with
      | Diff ->
        let w, h = t.diff_area in
        let view = Text_view.fit t.diff_view ~width:w ~rows:h in
        let total = List.length (Text_view.rows view ~width:w) in
        let top = Text_view.top view in
        let visual =
          match Text_view.visual view with
          | None -> ""
          | Some Characterwise -> " | VISUAL"
          | Some Linewise -> " | VISUAL LINE"
        in
        sprintf "Diff %d-%d/%d%s" (top + 1) (Int.min total (top + h)) total visual
        ^ hints
            (if String.is_empty visual
             then "s u x hunk, ] [ hunks, e open, 10j, v V y, Tab/Esc list, g r, @, q"
             else "s u x lines, S U, y copy, Esc ends, g r, @, q")
      | (Files | Branches | Commits) as focus ->
        let count = List.length (rows_of t focus) in
        let name =
          Option.value_map (panel t focus) ~default:"" ~f:(fun panel -> panel.title)
        in
        sprintf
          "%s %d/%d"
          name
          (Option.value_map (selected_index t focus) ~default:0 ~f:succ)
          count
        ^ hints
            (match focus with
             | Files -> "s u x S U, 1 2 3 panels, Tab diff, Enter, y copy, g r, @, q"
             | Branches | Commits | Diff -> "1 2 3 panels, Tab diff, Enter, y copy, g r, @, q"))
  in
  { title = title t
  ; footer = Some (Tile_shell.Label.footer ~notice ~pending ~default)
  ; body = compose ~width ~rows parts
  }
;;

let text_area t ~rows ~width =
  if Focus.equal t.focus Diff && loaded t && Option.is_some (layout t ~rows ~width).diff
  then Some (diff_text_rect t ~rows ~width)
  else None
;;

let key = Type_equal.Id.create ~name:"vcs" sexp_of_t

let adapter : (t, action) View_registry.Adapter.t =
  { spec
  ; key
  ; fit = (fun t _ ~rows ~width -> fit t ~rows ~width)
  ; leave
  ; text_view
  ; interpret
  ; escape
  ; hint =
      "VCS: s/u/x stage/unstage/discard, 1/2/3 panels, Tab diff, g r refresh, @ log, q \
       leaves, ? help"
  ; perform
  ; commands
  ; signal
  ; text_area
  ; render =
      (fun t _ ~hotkey_hints ~focused ~notice ~pending ~width ~rows ->
        render t ~hotkey_hints ~focused ~notice ~pending ~width ~rows)
  }
;;

let entry ?(placement = View_registry.Placement.Hidden) ?plan ~cwd () =
  View_registry.Entry.install ~placement ~opens_in:Tab adapter (create ?plan ~cwd ())
;;
