open! Core
open Ches_core
open Ches_input
open Ches_app

module Message = struct
  type kind =
    | Info
    | Warning
    | Error
  [@@deriving sexp_of, equal]

  type t =
    { kind : kind
    ; text : string
    }
  [@@deriving sexp_of, equal]
end

module Input = struct
  type t =
    | Key of Key.t
    | Paste_start
    | Paste_end
    | Animation_tick of Time_ns.t
    | Resize
  [@@deriving sexp_of]
end

type t =
  { controller : Controller.t
  ; prefs : Geometry.Prefs.t
  ; workspace_prefs : Workspace.Prefs.t
  ; other_status_size : int (** Requested size for the inactive split axis. *)
  ; zen : bool
  ; problems_visible : bool
  ; problems_current_document : bool
  ; problems_focus : bool
  ; problem_navigation : Problem_navigation.t
  ; problem_pending : Key.t list
  ; problem_details : bool
  ; problem_detail_top : int
  ; problem_notice : string option
  ; scroll : Scroll.t
  ; rows : int option
  (** Text rows the scroll was last fitted for: when they change, the fit fills the
      viewport (see {!Scroll.fit}). *)
  ; paste : (bool * string list) option (** Start owner (problems), chunks newest first. *)
  ; animation : Animation.t
  ; animation_time : Time_ns.t option
  ; exited : bool
  }

let create
  ?(prefs = Geometry.Prefs.default)
  ?(workspace_prefs = Workspace.Prefs.default)
  ?(smear_enabled = false)
  controller
  =
  { controller
  ; prefs
  ; workspace_prefs
  ; other_status_size =
      (match workspace_prefs.split.axis with
       | Horizontal -> 6
       | Vertical -> 28)
  ; zen = false
  ; problems_visible = false
  ; problems_current_document = false
  ; problems_focus = false
  ; problem_navigation = Problem_navigation.empty
  ; problem_pending = []
  ; problem_details = false
  ; problem_detail_top = 0
  ; problem_notice = None
  ; scroll = Scroll.zero
  ; rows = None
  ; paste = None
  ; animation = Animation.create ~enabled:smear_enabled
  ; animation_time = None
  ; exited = false
  }
;;

let controller t = t.controller
let prefs t = t.prefs
let workspace_prefs t = t.workspace_prefs
let zen t = t.zen
let problems_visible t = t.problems_visible
let problems_current_document t = t.problems_current_document
let scroll t = t.scroll

let message t =
  let feedback = Controller.feedback t.controller in
  let count = List.length (Ches_error.Error.problems feedback) in
  let presented = Ches_error.Error.presented_problem feedback in
  let notification = Ches_error.Error.notification feedback in
  match presented, notification with
  | Some _, Some notification ->
    let kind =
      match notification.severity with
      | Info -> Message.Info
      | Warning -> Warning
      | Error -> Error
    in
    let text =
      if count > 1
      then sprintf "[%d problems] %s" count notification.text
      else notification.text
    in
    Some { Message.kind; text }
  | _ ->
    let indicator =
      sprintf "[%d %s: Space v e]" count (if count = 1 then "problem" else "problems")
    in
    (match notification with
     | None when count = 0 -> None
     | None -> Some { Message.kind = Warning; text = indicator }
     | Some notification ->
       let kind =
         match notification.severity with
         | Info -> Message.Info
         | Warning -> Warning
         | Error -> Error
       in
       let text =
         if count = 0 then notification.text else indicator ^ " " ^ notification.text
       in
       Some { Message.kind; text })
;;

let pasting t = Option.is_some t.paste

let take_clipboard t =
  let controller, text = Controller.take_clipboard t.controller in
  { t with controller }, text
;;

let exited t = t.exited
let animation t = t.animation

let geometry_in t ~allocation ~reserve_status_row =
  Geometry.compute_in
    t.prefs
    ~allocation
    ~reserve_status_row
    ~line_count:(Text_buffer.line_count (Editor.text (Controller.editor t.controller)))
;;

let workspace t ~width ~height =
  let prefs = t.workspace_prefs in
  Workspace.allocate
    ~problems_visible:(t.problems_visible && not t.zen)
    (if t.zen then { prefs with status_visible = false } else prefs)
    ~allocation:{ Geometry.Rect.x = 0; y = 0; width; height }
;;

let problems_focused t ~width ~height =
  t.problems_focus && Option.is_some (workspace t ~width ~height).problems
;;

let problem_entries t =
  Problems.entries (Controller.feedback t.controller)
    ~current_document:t.problems_current_document
    ~path:(Editor.path (Controller.editor t.controller))
;;

let problem_rows t ~width ~height =
  Option.value_map (workspace t ~width ~height).problems ~default:1
    ~f:(fun pane -> Int.max 1 (pane.rect.height - 2))
;;

let problem_navigation t ~width ~height =
  Problem_navigation.fit t.problem_navigation (problem_entries t)
    ~rows:(problem_rows t ~width ~height)
;;

let selected_problem t ~width ~height =
  List.nth (problem_entries t) (problem_navigation t ~width ~height).index
;;

let problem_details t = t.problem_details
let problem_detail_top t = t.problem_detail_top
let problem_notice t = t.problem_notice
let problem_pending t =
  if List.is_empty t.problem_pending then None
  else Some (String.concat ~sep:" " (List.map t.problem_pending ~f:Key.to_string_hum))
;;

let return_to_document t =
  { t with problems_focus = false; problem_pending = []; problem_details = false;
    problem_notice = None;
    animation = Animation.create ~enabled:(Animation.enabled t.animation);
    controller = Controller.cancel_pending t.controller }
;;

let synchronize_problems t ~width ~height =
  let navigation = problem_navigation t ~width ~height in
  let changed = not ([%equal: Ches_error.Error.Identity.t option]
    navigation.selected t.problem_navigation.selected) in
  let t = { t with problem_navigation = navigation;
    problem_details = t.problem_details && not changed;
    problem_detail_top = if changed then 0 else t.problem_detail_top } in
  if t.problems_focus && not (problems_focused t ~width ~height)
  then return_to_document t else t
;;

let update_feedback t ~width ~height update =
  synchronize_problems
    { t with controller = Controller.update_feedback t.controller update } ~width ~height
;;

let geometry t ~width ~height =
  Workspace.document_geometry
    (workspace t ~width ~height)
    t.prefs
    ~line_count:(Text_buffer.line_count (Editor.text (Controller.editor t.controller)))
;;

(* The cursor's line and cells. A block insert's cursor is at its first insertion point,
   which before anything is typed can be inside a TAB or past the line's end, where the
   cursor's offset cannot be. *)
let cursor_cells editor =
  match Editor.block_insert_points editor with
  | (line, col) :: _ -> line, (col, 1)
  | [] ->
    let text = Editor.text editor in
    let line = Editor.cursor_line editor in
    ( line
    , Cell_map.cursor_span
        (Cell_map.glyphs (Text_buffer.line_text text line))
        ~pos:(Editor.cursor editor - Text_buffer.line_start text line)
        ~insertion:
          (match Editor.mode editor with
           | Insert -> true
           | Normal | Visual _ -> false) )
;;

let fitted_scroll_in t ~allocation ~reserve_status_row =
  let editor = Controller.editor t.controller in
  let text = Editor.text editor in
  let line, span = cursor_cells editor in
  let { Geometry.text = viewport; _ } = geometry_in t ~allocation ~reserve_status_row in
  Scroll.fit
    t.scroll
    ~fill:(not ([%equal: int option] t.rows (Some viewport.height)))
    ~line
    ~span
    ~rows:viewport.height
    ~cols:viewport.width
    ~line_count:(Text_buffer.line_count text)
;;

let cursor_position_in t ~allocation ~reserve_status_row =
  let cursor_line, (start, _) = cursor_cells (Controller.editor t.controller) in
  let scroll = fitted_scroll_in t ~allocation ~reserve_status_row in
  let { Geometry.text = viewport; _ } = geometry_in t ~allocation ~reserve_status_row in
  let x = start - scroll.left
  and y = cursor_line - scroll.top in
  if x >= 0 && x < viewport.width && y >= 0 && y < viewport.height
  then Some (viewport.x + x, viewport.y + y)
  else None
;;

let fitted_scroll t ~width ~height =
  let workspace = workspace t ~width ~height in
  fitted_scroll_in
    t
    ~allocation:workspace.document.rect
    ~reserve_status_row:workspace.reserve_status_row
;;

let cursor_position t ~width ~height =
  let workspace = workspace t ~width ~height in
  cursor_position_in
    t
    ~allocation:workspace.document.rect
    ~reserve_status_row:workspace.reserve_status_row
;;

let min_width = 20
let max_width = 500
let max_offset = 500

let apply_view (prefs : Geometry.Prefs.t) (view : View_command.t) : Geometry.Prefs.t =
  match view with
  | Toggle_centered -> { prefs with centered = not prefs.centered }
  | Toggle_absolute_numbers ->
    { prefs with line_numbers = Line_numbers.toggle_absolute prefs.line_numbers }
  | Toggle_relative_numbers ->
    { prefs with line_numbers = Line_numbers.toggle_relative prefs.line_numbers }
  | Reset -> Geometry.Prefs.default
  | Inspect_problems
  | Toggle_problems
  | Toggle_problems_filter
  | Focus_problems
  | Scroll _
  | Toggle_smear
  | Toggle_status
  | Position_status _
  | Adjust_status_size _
  | Toggle_zen -> prefs
  | Shift cells ->
    { prefs with
      centered = true
    ; offset = Int.clamp_exn (prefs.offset + cells) ~min:(-max_offset) ~max:max_offset
    }
  | Adjust_width cells ->
    { prefs with
      centered = true
    ; width = Int.clamp_exn (prefs.width + cells) ~min:min_width ~max:max_width
    }
;;

(* Feedback for [view], just applied: the requested value, then the effective one on this
   screen when it differs. *)
let view_feedback t ~width ~height (view : View_command.t) : string option =
  let geometry = geometry t ~width ~height in
  let with_fit requested effective ~to_string =
    if requested = effective
    then to_string requested
    else sprintf "%s (%s fit)" (to_string requested) (to_string effective)
  in
  let signed n = if n = 0 then "0" else sprintf "%+d" n in
  match view with
  | Focus_problems -> Some (Option.value t.problem_notice
      ~default:(if t.problems_focus then "Problems focused" else "Document focused"))
  | Inspect_problems | Scroll _ -> None
  | Toggle_problems ->
    Some (if not t.problems_visible then "Problems hidden"
      else if Option.is_none (workspace t ~width ~height).problems
      then "Problems requested (compact/zen)" else "Problems shown")
  | Toggle_problems_filter ->
    Some (if t.problems_current_document then "Problems: current document" else "Problems: workspace")
  | Toggle_smear ->
    Some
      (if Animation.enabled t.animation
       then "Smear cursor enabled"
       else "Smear cursor disabled")
  | Toggle_zen -> Some (if t.zen then "Zen (status hidden)" else "Workspace restored")
  | Toggle_status | Position_status _ | Adjust_status_size _ ->
    let requested = t.workspace_prefs in
    let location =
      match requested.split.axis, requested.split.first with
      | Horizontal, Status -> "left"
      | Horizontal, Document -> "right"
      | Vertical, Status -> "above"
       | Vertical, Document -> "below"
       | _, Problems -> "below"
    in
    let fitted = workspace t ~width ~height in
    let state =
      if t.zen
      then "saved for workspace; zen"
      else if not requested.status_visible
      then "hidden"
      else if Option.is_none fitted.status
      then "compact"
      else "shown"
    in
    let size =
      match fitted.status with
      | None -> Int.to_string requested.split.status_size
      | Some pane ->
        let effective =
          match requested.split.axis with
          | Horizontal -> pane.rect.width
          | Vertical -> pane.rect.height
        in
        with_fit requested.split.status_size effective ~to_string:Int.to_string
    in
    Some (sprintf "Status %s %s (%s)" location size state)
  | Toggle_centered -> Some (if t.prefs.centered then "Centered" else "Full width")
  | Toggle_absolute_numbers | Toggle_relative_numbers ->
    let style = t.prefs.line_numbers in
    let no_room = (not (Line_numbers.equal style Off)) && geometry.gutter.width = 0 in
    Some
      (sprintf
         "Line numbers: %s%s"
         (Line_numbers.to_string style)
         (if no_room then " (no room)" else ""))
  | Reset -> Some "Layout reset"
  | Shift _ -> Some ("Offset " ^ with_fit t.prefs.offset geometry.offset ~to_string:signed)
  | Adjust_width _ ->
    Some ("Width " ^ with_fit t.prefs.width geometry.text.width ~to_string:Int.to_string)
;;

(* [scroll] from the fitted scroll, with the cursor on screen. The new first line is kept
   within the document: [Ctrl-e] stops with the last line at the top. When the cursor line
   would leave the view, the cursor is moved by a counted [Up]/[Down], which keeps its
   preferred column. *)
let scroll_view t ~width ~height (scroll : View_command.Scroll.t) ~count =
  let rows = (geometry t ~width ~height).text.height in
  if rows <= 0
  then t
  else (
    let editor = Controller.editor t.controller in
    let line_count = Text_buffer.line_count (Editor.text editor) in
    let last = line_count - 1 in
    let line = Editor.cursor_line editor in
    let top = t.scroll.top in
    let half = Int.max 1 (rows / 2) in
    let top, target =
      match scroll with
      | Line_down -> Int.min last (top + Option.value count ~default:1), line
      | Line_up -> Int.max 0 (top - Option.value count ~default:1), line
      | Half_page_down ->
        let n = Option.value count ~default:half in
        (* Down to showing the last line at the bottom, but never back up. *)
        Int.max top (Int.min (top + n) (line_count - rows)), Int.min last (line + n)
      | Half_page_up ->
        let n = Option.value count ~default:half in
        Int.max 0 (top - n), Int.max 0 (line - n)
      | Cursor_middle -> Int.max 0 (line - ((rows - 1) / 2)), line
      | Cursor_top -> line, line
      | Cursor_bottom -> Int.max 0 (line - rows + 1), line
    in
    let target = Int.clamp_exn target ~min:top ~max:(Int.min last (top + rows - 1)) in
    let controller =
      if target > line
      then Controller.move t.controller Down ~count:(Some (target - line))
      else if target < line
      then Controller.move t.controller Up ~count:(Some (line - target))
      else t.controller
    in
    { t with controller; scroll = { t.scroll with top } })
;;

let apply_view_command t ~width ~height (view : View_command.t) =
  match view with
  | Focus_problems ->
    if t.problems_focus then return_to_document t
    else if not (Mode.equal (Editor.mode (Controller.editor t.controller)) Normal)
    then { t with problem_notice = Some "Leave Insert/Visual mode before focusing problems" }
    else
      let t = { t with problems_visible = true; problem_pending = [];
        controller = Controller.cancel_pending t.controller } in
      if Option.is_none (workspace t ~width ~height).problems
      then { t with problem_notice = Some "Problems cannot fit in compact/zen layout" }
      else { t with problems_focus = true; problem_notice = None }
  | Toggle_problems -> { t with problems_visible = not t.problems_visible }
  | Toggle_problems_filter ->
    { t with problems_current_document = not t.problems_current_document }
  | Inspect_problems ->
    { t with controller = Controller.update_feedback t.controller Inspect_next }
  | Scroll { scroll; count } -> scroll_view t ~width ~height scroll ~count
  | Toggle_smear ->
    { t with
      animation = Animation.set_enabled t.animation (not (Animation.enabled t.animation))
    }
  | Toggle_zen -> { t with zen = not t.zen }
  | Toggle_status ->
    { t with
      workspace_prefs =
        { t.workspace_prefs with status_visible = not t.workspace_prefs.status_visible }
    }
  | Position_status position ->
    let axis, first =
      match position with
      | Left -> Workspace.Split.Axis.Horizontal, Workspace.Pane_id.Status
      | Right -> Horizontal, Document
      | Above -> Vertical, Status
      | Below -> Vertical, Document
    in
    let split = t.workspace_prefs.split in
    let status_size, other_status_size =
      if Workspace.Split.Axis.equal axis split.axis
      then split.status_size, t.other_status_size
      else t.other_status_size, split.status_size
    in
    { t with
      other_status_size
    ; workspace_prefs = { status_visible = true; split = { axis; first; status_size } }
    }
  | Adjust_status_size cells ->
    let split = t.workspace_prefs.split in
    let minimum =
      match split.axis with
      | Horizontal -> Workspace.min_status_width
      | Vertical -> Workspace.min_status_height
    in
    let status_size = Int.clamp_exn (split.status_size + cells) ~min:minimum ~max:500 in
    { t with
      workspace_prefs = { t.workspace_prefs with split = { split with status_size } }
    }
  | Toggle_centered
  | Shift _
  | Adjust_width _
  | Toggle_absolute_numbers
  | Toggle_relative_numbers
  | Reset -> { t with prefs = apply_view t.prefs view }
;;

let feed t ~width ~height (input : Keymap.Input.t) =
  let controller, views, status = Controller.handle_input t.controller input in
  let t =
    List.fold views ~init:{ t with controller } ~f:(fun t view ->
      apply_view_command t ~width ~height view)
  in
  let notification =
    match Keymap.notice (Controller.keymap controller), List.last views with
    | Some text, _ -> Some (Ches_error.Error.Severity.Warning, "keymap", text)
    | None, Some view ->
      Option.map (view_feedback t ~width ~height view) ~f:(fun text ->
        Ches_error.Error.Severity.Info, "workspace", text)
    | None, None -> None
  in
  let controller =
    match notification with
    | None -> t.controller
    | Some (severity, source, text) ->
      Controller.update_feedback
        t.controller
        (Notify { source; scope = None; severity; text })
  in
  { t with controller }, status
;;

let pane_notice t text =
  { t with problem_notice = Some text; problem_pending = [];
    controller = Controller.update_feedback t.controller
      (Notify { source = "problems"; scope = Editor.path (Controller.editor t.controller);
        severity = Info; text }) }
;;

let select_problem t ~width ~height index =
  { t with
    problem_navigation = Problem_navigation.select (problem_navigation t ~width ~height)
      (problem_entries t) ~rows:(problem_rows t ~width ~height) index
  ; problem_details = false
  ; problem_detail_top = 0
  ; problem_notice = None
  ; problem_pending = []
  }
;;

let jump_to_problem t ~width ~height =
  match selected_problem t ~width ~height with
  | None -> pane_notice t "No problem selected"
  | Some problem ->
    let editor = Controller.editor t.controller in
    if not (Option.value_map (Editor.path editor) ~default:false
      ~f:(String.equal problem.identity.resource))
    then pane_notice t "Cross-file jump unavailable; current document kept"
    else match problem.location with
      | None -> pane_notice t "This problem has no document location"
      | Some location ->
        match Controller.jump t.controller ~line:location.line ~column:location.column with
        | Error error -> pane_notice t (Error.to_string_hum error)
        | Ok controller -> return_to_document { t with controller; problem_notice = None }
;;

let feed_problem t ~width ~height (input : Keymap.Input.t) =
  let t = match input with
    | Paste _ -> pane_notice t "Problems are read-only; paste ignored"
    | Key Escape ->
      if not (List.is_empty t.problem_pending)
      then { t with problem_pending = []; problem_notice = None }
      else if t.problem_details
      then { t with problem_details = false; problem_notice = None }
      else return_to_document t
    | Key (Ctrl 'c') -> pane_notice t "Escape returns to the editor"
    | Key Tab -> return_to_document t
    | Key key when not (List.is_empty t.problem_pending)
      && Key.equal (List.hd_exn t.problem_pending) (Key.char ' ') ->
      let keys = t.problem_pending @ [key] in
      (match Keymap.lookup (Controller.keymap t.controller) keys with
       | Prefix -> { t with problem_pending = keys; problem_notice = None }
       | Bound (View (Scroll _)) | Bound (Scroll _) ->
         pane_notice t "Document scrolling is unavailable in problems"
       | Bound (View view) ->
         apply_view_command { t with problem_pending = []; problem_notice = None }
           ~width ~height view
       | Bound _ -> pane_notice t "Editor command unavailable; Escape returns to editor"
       | Unbound -> pane_notice t "Unbound problems/workspace key")
    | Key key when not (List.is_empty t.problem_pending) ->
      if Key.equal key (Key.char 'g')
      then (if t.problem_details
        then { t with problem_pending = []; problem_detail_top = 0; problem_notice = None }
        else select_problem t ~width ~height 0)
      else pane_notice t "Cancelled problems prefix"
    | Key Enter -> jump_to_problem t ~width ~height
    | Key key when Key.equal key (Key.char ' ') || Key.equal key (Key.char 'g') ->
      { t with problem_pending = [key]; problem_notice = None }
    | Key key when Key.equal key (Key.char 'e') ->
      (match selected_problem t ~width ~height with
       | None -> pane_notice t "No problem selected"
       | Some problem ->
         { t with controller = Controller.update_feedback t.controller
             (Inspect_identity problem.identity);
           problem_details = not t.problem_details; problem_detail_top = 0;
           problem_notice = None })
    | Key key when Key.equal key (Key.char 'a') ->
      (match selected_problem t ~width ~height with
       | None -> pane_notice t "No problem selected"
       | Some problem ->
         { t with controller = Controller.update_feedback t.controller
             (Acknowledge_identity problem.identity);
           problem_notice = Some "Acknowledged; problem remains active" })
    | Key key when List.mem [Key.char 'j'; Key.char 'k'; Key.char 'G'; Ctrl 'd'; Ctrl 'u']
        key ~equal:Key.equal ->
      let rows = problem_rows t ~width ~height in
      let delta = match key with
        | Ctrl 'd' -> Int.max 1 (rows / 2)
        | Ctrl 'u' -> -(Int.max 1 (rows / 2))
        | _ when Key.equal key (Key.char 'k') -> -1
        | _ -> 1 in
      if t.problem_details then (
        let maximum = Option.value_map (selected_problem t ~width ~height) ~default:0
          ~f:(fun p -> Int.max 0 (List.length (Problems.detail_rows p ~width) - rows)) in
        { t with problem_detail_top =
            (if Key.equal key (Key.char 'G') then maximum else
              Int.clamp_exn (t.problem_detail_top + delta) ~min:0 ~max:maximum);
          problem_notice = None })
      else
        let index = if Key.equal key (Key.char 'G') then List.length (problem_entries t) - 1
          else (problem_navigation t ~width ~height).index + delta in
        select_problem t ~width ~height index
    | Key _ -> pane_notice t "Read-only problems: j/k e Enter a; Escape returns"
  in
  t, Controller.Status.Running
;;

let route t ~width ~height input =
  if problems_focused t ~width ~height then feed_problem t ~width ~height input
  else feed t ~width ~height input
;;

let refit t ~width ~height =
  let t = synchronize_problems t ~width ~height in
  { t with
    scroll = fitted_scroll t ~width ~height
  ; rows = Some (geometry t ~width ~height).text.height
  }
;;

let rec apply t ~width ~height (input : Input.t) =
  if t.exited then t, Controller.Status.Exit else apply_running t ~width ~height input

and apply_running t ~width ~height (input : Input.t) =
  (* Start from what is on screen: the stored scroll may predate a resize. *)
  let t = match input with
    | Resize -> synchronize_problems t ~width ~height
    | _ -> refit t ~width ~height in
  match input with
  | Resize -> t, Running
  | Animation_tick now ->
    let dt =
      Option.value_map t.animation_time ~default:0.017 ~f:(fun previous ->
        Time_ns.diff now previous |> Time_ns.Span.to_sec)
    in
    ( { t with animation = Animation.tick t.animation ~dt; animation_time = Some now }
    , Running )
  | Key _ | Paste_start | Paste_end ->
    let before = cursor_position t ~width ~height in
    let before_workspace = t.workspace_prefs
    and before_focus = t.problems_focus
    and before_problems_visible = t.problems_visible
    and before_zen = t.zen in
    let t, status =
      match input, t.paste with
      | Paste_start, None ->
        { t with paste = Some (problems_focused t ~width ~height, []) }, Controller.Status.Running
      | Paste_start, Some _ -> t, Running
      | Paste_end, None -> t, Running
      | Paste_end, Some (problems_owner, chunks) ->
        let t = { t with paste = None } in
        if problems_owner then
          pane_notice t "Problems are read-only; paste ignored", Running
        else feed ~width ~height t (Paste (String.concat (List.rev chunks)))
      | Key key, Some (problems_owner, chunks) ->
        (match Key.text key with
          | Some text -> { t with paste = Some (problems_owner, text :: chunks) }, Running
         | None -> t, Running)
      | Key key, None -> route ~width ~height t (Key key)
      | (Animation_tick _ | Resize), _ -> assert false
    in
    let t = refit t ~width ~height in
    let after = cursor_position t ~width ~height in
    let was_active = Animation.active t.animation in
    let animation =
      if (not (Workspace.Prefs.equal before_workspace t.workspace_prefs))
         || Bool.(before_problems_visible <> t.problems_visible)
         || Bool.(before_focus <> t.problems_focus)
         || Bool.(before_zen <> t.zen)
      then Animation.create ~enabled:(Animation.enabled t.animation)
      else Animation.retarget t.animation ~from:before ~to_:after
    in
    ( { t with
        animation
      ; animation_time =
          (if (not was_active) && Animation.active animation
           then None
           else t.animation_time)
      ; exited = Controller.Status.equal status Exit
      }
    , status )
;;

let apply_all t ~width ~height inputs =
  List.fold_until
    inputs
    ~init:t
    ~f:(fun t input ->
      match apply t ~width ~height input with
      | t, Running -> Continue t
      | t, Exit -> Stop (t, Controller.Status.Exit))
    ~finish:(fun t -> t, Running)
;;
