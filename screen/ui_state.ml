open! Core
open Ches_core
open Ches_input
open Ches_app
module Host = Ches_tile.Host
module View_id = Ches_tile.View_id

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
  ; host : Host.t (** Focus, capture prefix/notice, and paste owner. *)
  ; problems_visible : bool
  ; problems : Problems_tile.t
  ; report : Report_tile.t option (** Installed only by [--demo-report]. *)
  ; report_visible : bool
  ; scroll : Scroll.t
  ; rows : int option
  (** Text rows the scroll was last fitted for: when they change, the fit fills the
      viewport (see {!Scroll.fit}). *)
  ; animation : Animation.t
  ; animation_time : Time_ns.t option
  ; exited : bool
  }

let document_id = View_id.of_string "document"
let status_id = View_id.of_string "status"

let create
  ?(prefs = Geometry.Prefs.default)
  ?(workspace_prefs = Workspace.Prefs.default)
  ?(smear_enabled = false)
  ?report
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
  ; host =
      Host.create
        ~leader:(Key.char ' ')
        ~primary:document_id
        [ Ches_tile.Spec.primary document_id ~title:"Document"
        ; Ches_tile.Spec.companion status_id ~title:"Status"
        ; Problems_tile.spec
        ; Report_tile.spec
        ]
  ; problems_visible = false
  ; problems = Problems_tile.empty
  ; report = Option.map report ~f:Report_tile.create
  ; report_visible = false
  ; scroll = Scroll.zero
  ; rows = None
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
let problems_current_document t = Problems_tile.current_document t.problems
let problems_tile t = t.problems
let report t = t.report
let report_visible t = t.report_visible
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

let pasting t = Host.pasting t.host

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
  let minors =
    if t.zen
    then []
    else
      List.filter_opt
        [ Option.some_if t.problems_visible Problems_tile.id
        ; Option.some_if (t.report_visible && Option.is_some t.report) Report_tile.id
        ]
  in
  Workspace.allocate
    ~minors
    (if t.zen then { prefs with status_visible = false } else prefs)
    ~allocation:{ Geometry.Rect.x = 0; y = 0; width; height }
;;

let available t ~width ~height =
  let workspace = workspace t ~width ~height in
  fun id -> View_id.equal id document_id || Option.is_some (Workspace.minor workspace id)
;;

let focused_view t ~width ~height = Host.focused t.host ~available:(available t ~width ~height)

let cursor_owner t ~width ~height =
  Host.cursor_owner t.host ~available:(available t ~width ~height)
;;

let problems_focused t ~width ~height =
  View_id.equal (focused_view t ~width ~height) Problems_tile.id
;;

let minor_layout t ~width ~height id =
  Option.map (Workspace.minor (workspace t ~width ~height) id) ~f:(fun pane ->
    Tile_shell.layout Tile_shell.Policy.minor pane.rect)
;;

(* A minor view's content viewport: what it scrolls by and wraps to. *)
let minor_rows t ~width ~height id =
  Option.value_map (minor_layout t ~width ~height id) ~default:1
    ~f:(fun layout -> Int.max 1 layout.content.height)
;;

let minor_width t ~width ~height id =
  Option.value_map (minor_layout t ~width ~height id) ~default:width
    ~f:(fun layout -> layout.content.width)
;;

let path t = Editor.path (Controller.editor t.controller)

let fitted_problems t ~width ~height =
  Problems_tile.fit t.problems (Controller.feedback t.controller) ~path:(path t)
    ~rows:(minor_rows t ~width ~height Problems_tile.id)
    ~width:(minor_width t ~width ~height Problems_tile.id)
;;

let problem_navigation t ~width ~height =
  Problems_tile.selection (fitted_problems t ~width ~height)
;;

let selected_problem t ~width ~height =
  Problems_tile.selected t.problems (Controller.feedback t.controller) ~path:(path t)
    ~rows:(minor_rows t ~width ~height Problems_tile.id)
;;

(* A minor view's open read-only text, if any. *)
let text_view t id =
  if View_id.equal id Problems_tile.id
  then Problems_tile.text_view t.problems
  else if View_id.equal id Report_tile.id
  then Option.bind t.report ~f:Report_tile.text_view
  else None
;;

let text_cursor t ~width ~height =
  match Host.cursor_owner t.host ~available:(available t ~width ~height) with
  | None -> None
  | Some id when View_id.equal id document_id -> None
  | Some id ->
    Option.both (minor_layout t ~width ~height id) (text_view t id)
    |> Option.bind ~f:(fun ((layout : Tile_shell.Layout.t), view) ->
      let content = layout.content in
      let view =
        Ches_tile.Text_view.fit view ~width:content.width ~rows:content.height
      in
      let row, col = Ches_tile.Text_view.cursor_cell view ~width:content.width in
      let y = row - Ches_tile.Text_view.top view in
      Option.some_if
        (col < content.width && y >= 0 && y < content.height)
        (content.x + col, content.y + y))
;;

let problem_details t = Problems_tile.details t.problems
let problem_detail_top t = Problems_tile.detail_top t.problems
let capture_notice t = Host.notice t.host

let capture_pending t =
  match Host.pending t.host with
  | [] -> None
  | keys -> Some (String.concat ~sep:" " (List.map keys ~f:Key.to_string_hum))
;;

(* Close a view's capture-local state (details) when it stops being focused. *)
let leave t id =
  if View_id.equal id Problems_tile.id
  then { t with problems = Problems_tile.leave t.problems }
  else if View_id.equal id Report_tile.id
  then { t with report = Option.map t.report ~f:Report_tile.leave }
  else t
;;

let return_to_document t =
  let t = leave (leave t Problems_tile.id) Report_tile.id in
  { t with
    host = Host.return t.host
  ; animation = Animation.create ~enabled:(Animation.enabled t.animation)
  ; controller = Controller.cancel_pending t.controller
  }
;;

(* Fit each minor view's state to its viewport and source. When the source changes
   the text of open details, say so: the view never retargets a selection silently. *)
let synchronize t ~width ~height =
  let before = List.map [ Problems_tile.id; Report_tile.id ] ~f:(text_view t) in
  let t =
    { t with
      problems = fitted_problems t ~width ~height
    ; report =
        Option.map t.report
          ~f:(Report_tile.fit ~rows:(minor_rows t ~width ~height Report_tile.id)
                ~width:(minor_width t ~width ~height Report_tile.id))
    }
  in
  let after = List.map [ Problems_tile.id; Report_tile.id ] ~f:(text_view t) in
  let t =
    List.fold2_exn before after ~init:t ~f:(fun t before after ->
      match before, after with
      | Some before, Some after
        when not (String.equal (Ches_tile.Text_view.text before) (Ches_tile.Text_view.text after))
        ->
        let text =
          if Option.is_some (Ches_tile.Text_view.visual before)
          then "Details updated; selection cleared"
          else "Details updated"
        in
        { t with host = Host.with_notice t.host text }
      | _ -> t)
  in
  match Host.reconcile t.host ~available:(available t ~width ~height) with
  | _, `Kept -> t
  | _, `Returned _ -> return_to_document t
;;

let update_feedback t ~width ~height update =
  synchronize
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
  | Toggle_demo_report
  | Focus_demo_report
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

let demo_report_unavailable = "Demo report unavailable; launch with --demo-report"

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
  | Focus_problems | Focus_demo_report ->
    let focused = Host.spec t.host (focused_view t ~width ~height) in
    Some (Option.value (Host.notice t.host) ~default:(focused.title ^ " focused"))
  | Toggle_demo_report ->
    Some
      (match t.report with
       | None -> demo_report_unavailable
       | Some _ when not t.report_visible -> "Demo report hidden"
       | Some _ when Option.is_none (Workspace.minor (workspace t ~width ~height) Report_tile.id)
         -> "Demo report requested (compact/zen)"
       | Some _ -> "Demo report shown")
  | Inspect_problems | Scroll _ -> None
  | Toggle_problems ->
    Some (if not t.problems_visible then "Problems hidden"
      else if Option.is_none (Workspace.minor (workspace t ~width ~height) Problems_tile.id)
      then "Problems requested (compact/zen)" else "Problems shown")
  | Toggle_problems_filter ->
    Some (if problems_current_document t then "Problems: current document" else "Problems: workspace")
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
       | _, Minor _ -> "below"
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

(* Focus a minor view, showing it first, or return when it is already focused. Entry
   cancels pending editor input; an incomplete editor command keeps precedence because
   it never reaches here. *)
let toggle_focus t ~width ~height id ~show =
  let title = (Host.spec t.host id).title in
  let current = focused_view t ~width ~height in
  if View_id.equal current id
  then return_to_document t
  else if not (Mode.equal (Editor.mode (Controller.editor t.controller)) Normal)
  then
    { t with
      host =
        Host.with_notice t.host
          (sprintf "Leave Insert/Visual mode before focusing %s" (String.lowercase title))
    }
  else (
    let t = show { t with controller = Controller.cancel_pending t.controller } in
    if not (available t ~width ~height id)
    then { t with host = Host.with_notice t.host (title ^ " cannot fit in compact/zen layout") }
    else (
      let t = leave t current in
      { t with host = Host.focus t.host id }))
;;

let apply_view_command t ~width ~height (view : View_command.t) =
  match view with
  | Focus_problems ->
    toggle_focus t ~width ~height Problems_tile.id ~show:(fun t ->
      { t with problems_visible = true })
  | Focus_demo_report ->
    if Option.is_none t.report
    then { t with host = Host.with_notice t.host demo_report_unavailable }
    else
      toggle_focus t ~width ~height Report_tile.id ~show:(fun t ->
        { t with report_visible = true })
  | Toggle_demo_report ->
    if Option.is_none t.report then t else { t with report_visible = not t.report_visible }
  | Toggle_problems -> { t with problems_visible = not t.problems_visible }
  | Toggle_problems_filter -> { t with problems = Problems_tile.toggle_filter t.problems }
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

(* A capture notice in the focused view's footer, also reported as feedback from it. *)
let pane_notice t ~source text =
  { t with
    host = Host.with_notice t.host text
  ; controller =
      Controller.update_feedback
        t.controller
        (Notify
           { source = View_id.to_string source
           ; scope = path t
           ; severity = Info
           ; text
           })
  }
;;

(* What a view's read-only text asks for: copies go to the register and clipboard
   through the controller; rejections are capture notices from the view. *)
let text_effect t ~source (effect : Ches_tile.Text_view.Effect.t option) =
  match effect with
  | None -> t
  | Some (Copy register) ->
    { t with
      controller = Controller.yank t.controller register
    ; host = Host.with_notice t.host (Ches_tile.Text_view.Effect.describe_copy register)
    }
  | Some (Notice text) ->
    pane_notice t ~source (sprintf "%s: %s" (Host.spec t.host source).title text)
;;

(* A key typed into captured view [id]: the host decides, then the view's adapter
   performs its own actions. This is the only place adapters meet the host. *)
let feed_capture t ~width ~height id key =
  let lookup = Keymap.lookup (Controller.keymap t.controller) in
  let rows = minor_rows t ~width ~height id
  and cols = minor_width t ~width ~height id in
  let route ~content ~escape ~hint ~perform =
    let host, (decision : _ Host.Decision.t) =
      Host.key t.host key ~lookup ~content ~escape ~hint
    in
    let t = { t with host } in
    match decision with
    | Handled -> t
    | Return -> return_to_document t
    | Notice text -> pane_notice t ~source:id text
    | Workspace view -> apply_view_command t ~width ~height view
    | Content action -> perform t action
  in
  if View_id.equal id Problems_tile.id
  then
    route
      ~content:(Problems_tile.interpret t.problems)
      ~escape:(Problems_tile.escape t.problems)
      ~hint:Problems_tile.hint
      ~perform:(fun t action ->
        let { Problems_tile.Outcome.tile; controller; notice; effect; return } =
          Problems_tile.perform t.problems t.controller ~rows ~width:cols action
        in
        let t = text_effect { t with problems = tile; controller } ~source:id effect in
        let t =
          match notice with
          | None -> t
          | Some (`Post text) -> pane_notice t ~source:id text
          | Some (`Show text) -> { t with host = Host.with_notice t.host text }
        in
        if return then return_to_document t else t)
  else (
    match t.report with
    | Some report when View_id.equal id Report_tile.id ->
      route
        ~content:(Report_tile.interpret report)
        ~escape:(Report_tile.escape report)
        ~hint:Report_tile.hint
        ~perform:(fun t action ->
          let report, effect = Report_tile.perform report ~rows ~width:cols action in
          text_effect { t with report = Some report } ~source:id effect)
    | Some _ | None -> return_to_document t)
;;

let route t ~width ~height key =
  match Host.capturing t.host ~available:(available t ~width ~height) with
  | Some id -> feed_capture t ~width ~height id key, Controller.Status.Running
  | None -> feed t ~width ~height (Key key)
;;

let refit t ~width ~height =
  let t = synchronize t ~width ~height in
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
    | Resize -> synchronize t ~width ~height
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
    and before_focus = focused_view t ~width ~height
    and before_problems_visible = t.problems_visible
    and before_report_visible = t.report_visible
    and before_zen = t.zen in
    let t, status =
      match input with
      | Paste_start ->
        ( { t with host = Host.paste_start t.host ~available:(available t ~width ~height) }
        , Controller.Status.Running )
      | Paste_end ->
        (match Host.paste_end t.host with
         | host, `Not_pasting -> { t with host }, Running
         | host, `Deliver (owner, text) when View_id.equal owner document_id ->
           feed ~width ~height { t with host } (Paste text)
         | host, `Deliver (owner, _) ->
           pane_notice { t with host } ~source:owner "Paste is unsupported here", Running
         | host, `Reject (owner, text) -> pane_notice { t with host } ~source:owner text, Running)
      | Key key when Host.pasting t.host -> { t with host = Host.paste_key t.host key }, Running
      | Key key -> route ~width ~height t key
      | Animation_tick _ | Resize -> assert false
    in
    let t = refit t ~width ~height in
    let after = cursor_position t ~width ~height in
    let was_active = Animation.active t.animation in
    let animation =
      if (not (Workspace.Prefs.equal before_workspace t.workspace_prefs))
         || Bool.(before_problems_visible <> t.problems_visible)
         || Bool.(before_report_visible <> t.report_visible)
         || not (View_id.equal before_focus (focused_view t ~width ~height))
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
