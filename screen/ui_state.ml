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
    | Source of Ches_error.Source_event.t
  [@@deriving sexp_of]
end

type t =
  { controller : Controller.t
  ; session : Session.t
  ; scrolls : (Buffer_id.t * Scroll.t) list
  ; paste_buffer : Buffer_id.t option
  ; prefs : Geometry.Prefs.t
  ; workspace_prefs : Workspace.Prefs.t
  ; other_status_size : int (** Requested size for the inactive split axis. *)
  ; hotkey_hints : bool
  ; buffer_presentation : View_command.Buffer_presentation.t
  ; zen : bool
  ; directory_size : int
  ; hide_tabs : bool (** Rendering-only directory surface snapshot. *)
  ; host : Host.t (** Focus, capture prefix/notice, and paste owner. *)
  ; problems_visible : bool
  ; problems : Problems_tile.t
  ; report : Report_tile.t option (** Installed only by [--demo-report]. *)
  ; report_visible : bool
  ; history_visible : bool
  ; history : History_tile.t
  ; palette : Palette_tile.t option (** Open, and then focused, or closed. *)
  ; scroll : Scroll.t
  ; rows : int option
  (** Text rows the scroll was last fitted for: when they change, the fit fills the
      viewport (see {!Scroll.fit}). *)
  ; animation : Animation.t
  ; animation_time : Time_ns.t option
  ; exited : bool
  ; held : ((string * string) * Ches_error.Error.update * Text_buffer.t) list
  (** Diagnostic snapshots that arrived during Insert, newest per (source, resource),
      in arrival order, with the text at arrival; applied when Insert ends. *)
  ; source_attached : bool (** A diagnostic source runs ([--synthetic-checker]). *)
  ; sent_revisions : (Buffer_id.t * (int * int)) list
  ; source_commands : Ches_error.Source_request.t list
  (** Restart/kill requests not yet taken, newest first. *)
  }

let document_id = View_id.of_string "document"
let status_id = View_id.of_string "status"
let directory_id = View_id.of_string "directory"

let create
  ?(prefs = Geometry.Prefs.default)
  ?workspace_prefs
  ?(tiles_visible = true)
  ?(hotkey_hints = false)
  ?(buffer_presentation = View_command.Buffer_presentation.Top)
  ?directory_config
  ?(smear_enabled = false)
  ?report
  ?(source_attached = false)
  controller
  =
  let workspace_prefs =
    Option.value workspace_prefs
      ~default:{ Workspace.Prefs.default with status_visible = tiles_visible }
  in
  let session = Session.create ?directory_config ~cell_width:Cell_map.width controller in
  let controller = Option.value_exn (Session.active_controller session) in
  { controller
  ; session
  ; scrolls = []
  ; paste_buffer = None
  ; prefs
  ; workspace_prefs
  ; other_status_size =
      (match workspace_prefs.split.axis with
       | Horizontal -> 6
       | Vertical -> 28)
  ; hotkey_hints
  ; buffer_presentation
  ; zen = false
  ; directory_size = 32
  ; hide_tabs = false
  ; host =
      Host.create
        ~leader:(Key.char ' ')
        ~primary:document_id
        [ Ches_tile.Spec.primary document_id ~title:"Document"
        ; Ches_tile.Spec.companion status_id ~title:"Status"
        ; Problems_tile.spec
        ; Report_tile.spec
        ; History_tile.spec
        ; Palette_tile.spec
        ; Ches_tile.Spec.read_only_text directory_id ~title:"Directory"
        ]
  ; problems_visible = tiles_visible
  ; problems = Problems_tile.empty
  ; report = Option.map report ~f:Report_tile.create
  ; report_visible = tiles_visible && Option.is_some report
  ; history_visible = tiles_visible
  ; history = History_tile.empty
  ; palette = None
  ; scroll = Scroll.zero
  ; rows = None
  ; animation = Animation.create ~enabled:smear_enabled
  ; animation_time = None
  ; exited = false
  ; held = []
  ; source_attached
  ; sent_revisions = []
  ; source_commands = []
  }
;;

let controller t = t.controller
let session t = Session.replace_active t.session t.controller
let has_document t = Option.is_some (Session.context_id t.session)
let prefs t = t.prefs
let workspace_prefs t = t.workspace_prefs
let hotkey_hints t = t.hotkey_hints
let buffer_presentation t = t.buffer_presentation
let zen t = t.zen
let problems_visible t = t.problems_visible
let problems_current_document t = Problems_tile.current_document t.problems
let problems_tile t = t.problems
let report t = t.report
let report_visible t = t.report_visible
let history_visible t = t.history_visible
let history_tile t = t.history
let palette t = t.palette
let scroll t = t.scroll

let message t =
  let feedback = Controller.feedback t.controller in
  let count = Problems.count feedback in
  let presented = Ches_error.Error.presented_problem feedback in
  let notification = Ches_error.Error.notification feedback in
  match presented, notification with
  | Some _, Some notification ->
    let kind =
      match notification.severity with
      | Hint | Info -> Message.Info
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
         | Hint | Info -> Message.Info
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
  let session, text = Session.take_clipboard (session t) in
  let controller = Option.value (Session.active_controller session) ~default:t.controller in
  { t with session; controller }, text
;;

let take_source_requests t =
  if not t.source_attached
  then (
    let session, _ = Session.take_saved (session t) in
    let session, _ = Session.take_closed session in
    let controller = Option.value (Session.active_controller session) ~default:t.controller in
    { t with session; controller; source_commands = [] }, [])
  else (
    let session, saved = Session.take_saved (session t) in
    let session, closed = Session.take_closed session in
    let live = Session.buffers session in
    let document = List.concat_map live ~f:(fun (id, controller) ->
      let editor = Controller.editor controller in
      match Editor.path editor with
      | None -> []
      | Some resource ->
        let previous = List.Assoc.find t.sent_revisions id ~equal:Buffer_id.equal in
        let generation = Session.source_generation session id |> Option.value_exn in
        let same_lifetime = Option.exists previous ~f:(fun (old, _) -> old = generation) in
        let opened = if not same_lifetime then [ Ches_error.Source_request.Document_opened { resource; generation } ] else [] in
        opened @ (if Option.equal Poly.equal previous (Some (generation, Editor.revision editor)) then [] else
          [ Document_changed { resource; text = Text_buffer.to_string (Editor.text editor); revision = Editor.revision editor } ])) in
    let sent_revisions = List.map live ~f:(fun (id, c) -> id, (Session.source_generation session id |> Option.value_exn, Editor.revision (Controller.editor c))) in
    let saves = List.map saved ~f:(fun { Controller.Saved.path; revision } -> Ches_error.Source_request.Document_saved { resource = path; revision }) in
    let closes = List.map closed ~f:(fun resource -> Ches_error.Source_request.Document_closed { resource }) in
    let controller = Option.value (Session.active_controller session) ~default:t.controller in
    ( { t with session; controller; sent_revisions; source_commands = [] }
    , closes @ document @ saves @ List.rev t.source_commands ))
;;

let exited t = t.exited
let animation t = t.animation

let tab_rect ?(buffers_in_status = false) t ~(allocation : Geometry.Rect.t) =
  if not buffers_in_status && not t.hide_tabs
     && not (Option.is_some (Session.input_directory t.session)
       && Option.exists (Session.directory_presentation t.session) ~f:(fun p -> Poly.equal p.placement Side))
     && List.length (Session.buffers t.session) > 1
     && not t.zen && allocation.width > 0 && allocation.height >= 3
  then Some { allocation with height = 1 }
  else None
;;

let directory_rect ?(buffers_in_status = false) t ~(allocation : Geometry.Rect.t) =
  let allocation = match tab_rect ~buffers_in_status t ~allocation with None -> allocation | Some _ ->
    { allocation with y = allocation.y + 1; height = allocation.height - 1 } in
  if Option.is_some (Session.input_directory t.session) && allocation.height >= 2 && allocation.width > 0
  then Some { allocation with height = 1 } else None
;;

let geometry_in ?(buffers_in_status = false) t ~allocation ~reserve_status_row =
  let header = directory_rect ~buffers_in_status t ~allocation in
  let allocation = match tab_rect ~buffers_in_status t ~allocation with
    | None -> allocation
    | Some _ -> { allocation with y = allocation.y + 1; height = allocation.height - 1 } in
  let allocation = match header with None -> allocation | Some _ ->
    { allocation with y = allocation.y + 1; height = allocation.height - 1 } in
  Geometry.compute_in
    (if Option.is_some (Session.input_directory t.session) then
       if Option.exists (Session.directory_presentation t.session) ~f:(fun p -> Poly.equal p.placement Side)
       then { t.prefs with line_numbers = Absolute; centered = false; left_padding = 0 }
       else { t.prefs with line_numbers = Absolute }
     else t.prefs)
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
        [ (* First, so that opening never fails for width while the band has room. *)
          Option.some_if (Option.is_some t.palette) Palette_tile.id
        ; Option.some_if t.problems_visible Problems_tile.id
        ; Option.some_if (t.report_visible && Option.is_some t.report) Report_tile.id
        ; Option.some_if t.history_visible History_tile.id
        ]
  in
  Workspace.allocate
    ~minors
    ?side:(Option.bind (Session.directory_presentation t.session) ~f:(fun p ->
      Option.some_if (Poly.equal p.placement Side && not t.zen && Option.is_some (Session.active_id t.session))
        (directory_id, t.directory_size)))
    (if t.zen then { prefs with status_visible = false } else prefs)
    ~allocation:{ Geometry.Rect.x = 0; y = 0; width; height }
;;

let buffers_in_status t ~width ~height =
  View_command.Buffer_presentation.equal t.buffer_presentation Status_rows
  && Option.exists (workspace t ~width ~height).status ~f:(fun pane ->
    let content = (Tile_shell.layout Tile_shell.Policy.status pane.rect).content in
    content.width > 0 && content.height > 0)
;;

(* A supplied floating identity overrides its tiled placement, including when
   resize makes its layout unavailable. The docked palette will opt into this
   layer when its compositor is ready; existing callers retain tiled behavior. *)
let view_layout_in ?floating (workspace : Workspace.t) id =
  if View_id.equal id document_id
  then None
  else match floating with
  | Some (floating_id, layout) when View_id.equal id floating_id -> layout
  | _ ->
    if View_id.equal id status_id
    then Option.map workspace.status ~f:(fun pane ->
      Tile_shell.layout Tile_shell.Policy.status pane.rect)
    else
      Option.map (Workspace.minor workspace id) ~f:(fun pane ->
        Tile_shell.layout Tile_shell.Policy.minor pane.rect)
;;

let view_layout ?floating t ~width ~height id =
  view_layout_in ?floating (workspace t ~width ~height) id
;;

let view_available ?floating t ~width ~height =
  let workspace = workspace t ~width ~height in
  fun id ->
    View_id.equal id document_id
    || Option.is_some (view_layout_in ?floating workspace id)
;;

let available t ~width ~height = view_available t ~width ~height

let side_layout t ~width ~height = view_layout t ~width ~height directory_id

let input_allocation t ~width ~height =
  match Session.input_directory t.session, side_layout t ~width ~height with
  | Some _, Some layout -> layout.content, false
  | _ -> let w = workspace t ~width ~height in w.document.rect, w.reserve_status_row
;;

let focused_view t ~width ~height = Host.focused t.host ~available:(available t ~width ~height)

let cursor_owner t ~width ~height =
  Option.filter (Host.cursor_owner t.host ~available:(available t ~width ~height))
    ~f:(fun id -> not (View_id.equal id document_id) || has_document t)
;;

let surface t ~directory =
  let session = Session.surface (session t) ~directory in
  let id = Session.context_id session in
  let scroll = if Option.equal Buffer_id.equal id (Session.context_id t.session) then t.scroll else
    Option.value (Option.bind id ~f:(fun id -> List.Assoc.find t.scrolls id ~equal:Buffer_id.equal)) ~default:Scroll.zero in
  { t with session; controller = Option.value (Session.active_controller session) ~default:t.controller
    ; scroll; rows = None; hide_tabs = directory
    ; prefs = (if directory then { t.prefs with centered = false; left_padding = 0 } else t.prefs) }
;;

let problems_focused t ~width ~height =
  View_id.equal (focused_view t ~width ~height) Problems_tile.id
;;

let minor_layout t ~width ~height id =
  if View_id.equal id status_id || View_id.equal id document_id
  then None
  else view_layout t ~width ~height id
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
let document t = Problems_tile.document t.problems (Controller.editor t.controller)

let fitted_problems t ~width ~height =
  Problems_tile.fit t.problems (Controller.feedback t.controller) ~document:(document t)
    ~rows:(minor_rows t ~width ~height Problems_tile.id)
    ~width:(minor_width t ~width ~height Problems_tile.id)
;;

let problem_navigation t ~width ~height =
  Problems_tile.selection (fitted_problems t ~width ~height)
;;

let selected_problem t ~width ~height =
  Problems_tile.selected t.problems (Controller.feedback t.controller) ~document:(document t)
    ~rows:(minor_rows t ~width ~height Problems_tile.id)
;;

(* A minor view's open read-only text, if any. *)
let text_view t id =
  if View_id.equal id Problems_tile.id
  then Problems_tile.text_view t.problems
  else if View_id.equal id Report_tile.id
  then Option.bind t.report ~f:Report_tile.text_view
  else if View_id.equal id History_tile.id
  then History_tile.text_view t.history
  else None
;;

(* Where minor view [id]'s adapter wants the cursor in its [content] area. The palette
   puts a bar after its query; a view with open read-only text puts a block on its text
   cursor; others want none. *)
let cursor_intent t id ~(content : Geometry.Rect.t) : Ches_tile.Cursor.t option =
  if View_id.equal id Palette_tile.id
  then Option.map t.palette ~f:(Palette_tile.cursor ~width:content.width)
  else
    Option.map (text_view t id) ~f:(fun view ->
      let view = Ches_tile.Text_view.fit view ~width:content.width ~rows:content.height in
      let row, column = Ches_tile.Text_view.cursor_cell view ~width:content.width in
      { Ches_tile.Cursor.row = row - Ches_tile.Text_view.top view; column; shape = Block })
;;

let supporting_cursor t ~width ~height =
  match Host.cursor_owner t.host ~available:(available t ~width ~height) with
  | None -> None
  | Some id when View_id.equal id document_id -> None
  | Some id ->
    Option.bind (minor_layout t ~width ~height id) ~f:(fun (layout : Tile_shell.Layout.t) ->
      let content = layout.content in
      Option.bind (cursor_intent t id ~content) ~f:(fun { row; column; shape } ->
        Option.some_if
          (column >= 0 && column < content.width && row >= 0 && row < content.height)
          (content.x + column, content.y + row, shape)))
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
  else if View_id.equal id History_tile.id
  then { t with history = History_tile.leave t.history }
  else if View_id.equal id Palette_tile.id
  then (* Leaving closes the palette and discards its query; nothing runs. *)
    { t with palette = None }
  else t
;;

let minor_ids = [ Problems_tile.id; Report_tile.id; History_tile.id; Palette_tile.id ]

let return_to_document t =
  let t = List.fold minor_ids ~init:t ~f:leave in
  { t with
    host = (let host = Host.return t.host in
      if Option.is_some (Session.input_directory t.session)
         && Option.is_some (Session.active_id t.session)
         && Option.exists (Session.directory_presentation t.session) ~f:(fun p -> Poly.equal p.placement Side)
      then Host.focus host directory_id else host)
  ; animation = Animation.create ~enabled:(Animation.enabled t.animation)
  ; controller = Controller.cancel_pending t.controller
  }
;;

(* Fit each minor view's state to its viewport and source. When the source changes
   the text of open details, say so: the view never retargets a selection silently. *)
let synchronize t ~width ~height =
  (* Suppressed side placement keeps its request/buffer, but must never retain
     invisible input focus. With no files, the directory remains the major surface. *)
  let t = if Option.is_some (Session.input_directory t.session)
      && Option.is_some (Session.active_id t.session)
      && Option.exists (Session.directory_presentation t.session) ~f:(fun p -> Poly.equal p.placement Side)
      && Option.is_none (side_layout t ~width ~height)
    then
      let old = Session.context_id t.session in
      let scrolls = Option.value_map old ~default:t.scrolls ~f:(fun id -> List.Assoc.add t.scrolls ~equal:Buffer_id.equal id t.scroll) in
      let session = Session.focus_directory (session t) false in
      let scroll = Option.value (Option.bind (Session.context_id session) ~f:(fun id -> List.Assoc.find scrolls id ~equal:Buffer_id.equal)) ~default:Scroll.zero in
      { (return_to_document t) with session; controller = Option.value_exn (Session.active_controller session)
        ; scrolls; scroll; rows = None; paste_buffer = None }
    else t in
  let before = List.map minor_ids ~f:(text_view t) in
  let t =
    { t with
      problems = fitted_problems t ~width ~height
    ; report =
        Option.map t.report
          ~f:(Report_tile.fit ~rows:(minor_rows t ~width ~height Report_tile.id)
                ~width:(minor_width t ~width ~height Report_tile.id))
    ; history =
        History_tile.fit t.history
          (Ches_error.Error.history (Controller.feedback t.controller))
          ~rows:(minor_rows t ~width ~height History_tile.id)
          ~width:(minor_width t ~width ~height History_tile.id)
    ; palette =
        Option.map t.palette
          ~f:(Palette_tile.fit ~rows:(minor_rows t ~width ~height Palette_tile.id))
    }
  in
  let after = List.map minor_ids ~f:(text_view t) in
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
  let allocation, reserve_status_row = input_allocation t ~width ~height in
  geometry_in ~buffers_in_status:(buffers_in_status t ~width ~height) t ~allocation ~reserve_status_row
;;

(* All tab paths share lifetime, viewport, prefix and paste reconciliation. Held
   diagnostics are released by the input assembly or the public lifecycle facade. *)
let adopt_session_state t session ~width ~height =
  let retired = List.filter_map (Session.buffers t.session) ~f:(fun (id, controller) ->
    if Option.equal Int.equal (Session.source_generation t.session id) (Session.source_generation session id)
    then None else Editor.path (Controller.editor controller)) in
  let t = { t with held = List.filter t.held ~f:(fun ((_, resource), _, _) ->
    not (List.mem retired (Session.normalize t.session resource) ~equal:String.equal))
    ; problems = List.fold retired ~init:t.problems ~f:Problems_tile.forget_resource } in
  let previous = Session.context_id t.session in
  let changed = not (Option.equal Buffer_id.equal previous (Session.context_id session)) in
  let placement_changed = not (Option.equal Poly.equal
    (Option.map (Session.directory_presentation t.session) ~f:(fun p -> p.placement))
    (Option.map (Session.directory_presentation session) ~f:(fun p -> p.placement))) in
  let tabs_changed = not (Bool.equal
    (List.length (Session.buffers t.session) > 1)
    (List.length (Session.buffers session) > 1)) in
  let scrolls = match previous with
    | None -> t.scrolls
    | Some id -> List.Assoc.add t.scrolls ~equal:Buffer_id.equal id t.scroll in
  let scrolls = List.filter scrolls ~f:(fun (id, _) -> Session.has_buffer session id) in
  let controller = Option.value (Session.active_controller session)
    ~default:(Controller.with_feedback t.controller (Session.feedback session)) in
  let t = { t with session; controller; scrolls; exited = Session.exited session } in
  let t = if not changed then
    (if placement_changed then { t with rows = None; paste_buffer = None
        ; host = Host.return t.host; controller = Controller.cancel_pending t.controller
        ; animation = Animation.create ~enabled:(Animation.enabled t.animation) } else
    (if not tabs_changed then t else
       { t with rows = None; animation = Animation.create ~enabled:(Animation.enabled t.animation) }))
    else
    let scroll = Option.value (Option.bind (Session.context_id session) ~f:(fun id -> List.Assoc.find scrolls id ~equal:Buffer_id.equal)) ~default:Scroll.zero in
    { (return_to_document t) with scroll; rows = None; paste_buffer = None
      ; animation = Animation.create ~enabled:(Animation.enabled t.animation) } in
  let t = synchronize t ~width ~height in
  if Option.is_some (Session.input_directory t.session) && Option.is_some (side_layout t ~width ~height)
     && Option.is_none t.palette
  then { t with host = Host.focus t.host directory_id }
  else t
;;

let close_buffer_state t ~width ~height id ~force =
  let session = session t in
  let resource = Option.bind (Session.find session id) ~f:(fun c -> Editor.path (Controller.editor c)) in
  let session, closed = Session.close_buffer session id ~force in
  let t = { t with held = List.filter t.held ~f:(fun ((_, resource), _, _) -> Option.is_some (Session.find_resource session resource)) } in
  let t = if not closed then t else Option.value_map resource ~default:t ~f:(fun resource ->
    { t with problems = Problems_tile.forget_resource t.problems resource }) in
  adopt_session_state t session ~width ~height, closed
;;

let switch_tab t ~width ~height ~direction =
  let session = session t in
  let ids = List.map (Session.buffers session) ~f:fst in
  match Session.active_id session with
  | None -> t
  | Some active ->
    let index = List.findi_exn ids ~f:(fun _ id -> Buffer_id.equal id active) |> fst in
    let target = List.nth_exn ids ((index + direction + List.length ids) % List.length ids) in
    adopt_session_state t (Session.activate session target |> Or_error.ok_exn) ~width ~height
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

let fitted_scroll_in ?(buffers_in_status = false) t ~allocation ~reserve_status_row =
  let editor = Controller.editor t.controller in
  let text = Editor.text editor in
  let line, span = cursor_cells editor in
  let { Geometry.text = viewport; _ } = geometry_in ~buffers_in_status t ~allocation ~reserve_status_row in
  Scroll.fit
    t.scroll
    ~fill:(not ([%equal: int option] t.rows (Some viewport.height)))
    ~line
    ~span
    ~rows:viewport.height
    ~cols:viewport.width
    ~line_count:(Text_buffer.line_count text)
;;

let cursor_position_in ?(buffers_in_status = false) t ~allocation ~reserve_status_row =
  if not (has_document t) then None else
  let cursor_line, (start, _) = cursor_cells (Controller.editor t.controller) in
  let scroll = fitted_scroll_in ~buffers_in_status t ~allocation ~reserve_status_row in
  let { Geometry.text = viewport; _ } = geometry_in ~buffers_in_status t ~allocation ~reserve_status_row in
  let x = start - scroll.left
  and y = cursor_line - scroll.top in
  if x >= 0 && x < viewport.width && y >= 0 && y < viewport.height
  then Some (viewport.x + x, viewport.y + y)
  else None
;;

let fitted_scroll t ~width ~height =
  let allocation, reserve_status_row = input_allocation t ~width ~height in
  fitted_scroll_in
    ~buffers_in_status:(buffers_in_status t ~width ~height)
    t
    ~allocation
    ~reserve_status_row
;;

let cursor_position t ~width ~height =
  let allocation, reserve_status_row = input_allocation t ~width ~height in
  cursor_position_in
    ~buffers_in_status:(buffers_in_status t ~width ~height)
    t
    ~allocation
    ~reserve_status_row
;;

let minor_cursor t ~width ~height =
  if View_id.equal (focused_view t ~width ~height) directory_id then
    Option.map (cursor_position t ~width ~height) ~f:(fun (x, y) -> x, y, Ches_tile.Cursor.Shape.Block)
  else supporting_cursor t ~width ~height
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
   | Next_tab | Previous_tab | Present_buffers _ | Close_tab | Force_close_tab | Recreate_missing_file
  | Toggle_entry_mark | Mark_selection | Unmark_selection | Clear_directory_marks | Open_marked_files
  | Toggle_directory | Open_directory_entry | Directory_parent | Refresh_directory
  | Directory_major | Directory_side | Hide_directory | Focus_directory | Adjust_directory_size _
  | Toggle_problems
  | Toggle_problems_filter
  | Focus_problems
  | Toggle_demo_report
  | Focus_demo_report
  | Toggle_history
  | Focus_history
  | Restart_source
  | Kill_source
  | Scroll _
  | Toggle_smear
  | Toggle_status
  | Toggle_hotkey_hints
  | Position_status _
  | Adjust_status_size _
  | Toggle_zen
  | Open_palette -> prefs
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
let no_source = "No diagnostic source; launch with --synthetic-checker"

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
  | Present_buffers presentation -> Some
      (match presentation with
       | Top -> "Open buffers in top strip"
       | Status_rows -> if t.zen then "Buffer rows saved for workspace; zen"
         else if buffers_in_status t ~width ~height then "Open buffers in status rows"
         else "Status rows requested (top strip fallback)")
  | Focus_problems | Focus_demo_report | Focus_history ->
    let focused = Host.spec t.host (focused_view t ~width ~height) in
    Some (Option.value (Host.notice t.host) ~default:(focused.title ^ " focused"))
  | Toggle_entry_mark | Mark_selection | Unmark_selection | Clear_directory_marks | Open_marked_files
  | Toggle_directory | Open_directory_entry | Directory_parent | Refresh_directory -> None
  | Directory_major -> Option.map (Session.directory_presentation t.session) ~f:(fun _ -> "Directory in major tile")
  | Directory_side -> Option.map (Session.directory_presentation t.session) ~f:(fun _ ->
      if Option.is_some (side_layout t ~width ~height) then "Directory in left side tile" else "Directory side requested (compact/zen/no file)")
  | Hide_directory -> None
  | Focus_directory -> Option.map (Session.directory_presentation t.session) ~f:(fun _ ->
      if Option.is_some (Session.input_directory t.session) then "Directory focused" else "Editor focused")
  | Adjust_directory_size _ -> Some (sprintf "Directory width %d (requested)" t.directory_size)
  | Toggle_demo_report ->
    Some
      (match t.report with
       | None -> demo_report_unavailable
       | Some _ when not t.report_visible -> "Demo report hidden"
       | Some _ when Option.is_none (Workspace.minor (workspace t ~width ~height) Report_tile.id)
         -> "Demo report requested (compact/zen)"
       | Some _ -> "Demo report shown")
  | Toggle_history ->
    Some (if not t.history_visible then "History hidden"
      else if Option.is_none (Workspace.minor (workspace t ~width ~height) History_tile.id)
      then "History requested (compact/zen)" else "History shown")
  | Restart_source ->
    Some (if t.source_attached then "Diagnostic source restart requested" else no_source)
  | Kill_source ->
    Some (if t.source_attached then "Diagnostic source kill requested" else no_source)
   | Inspect_problems | Scroll _ | Next_tab | Previous_tab | Close_tab | Force_close_tab | Recreate_missing_file -> None
  | Open_palette -> Host.notice t.host
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
  | Toggle_hotkey_hints ->
    Some (if t.hotkey_hints then "Hotkey hints shown" else "Hotkey hints hidden")
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

let palette_title = "Command palette"

(* Open the palette for the document, focused. It opens only in Normal mode, and needs
   room in the bottom band (it goes first there, so only a compact layout or zen leaves
   none). From another minor view it leaves that view: the document is the target. *)
let open_palette t ~width ~height =
  let notice text = { t with host = Host.with_notice t.host text } in
  let editor = Controller.editor t.controller in
  if not (has_document t)
  then notice "No file open; Space q quits the session"
  else if not (Mode.equal (Editor.mode editor) Normal)
  then notice "Leave Insert/Visual mode before opening the command palette"
  else if t.zen
  then notice "Command palette unavailable in zen; Space v z restores the workspace"
  else (
    let palette =
      Palette_tile.create
        Ches_palette.Catalog.default
        { mode = Editor.mode editor }
        ~token:document_id
        ~bindings:(Bindings.to_list (Keymap.bindings (Controller.keymap t.controller)))
    in
    let current = focused_view t ~width ~height in
    let t =
      { (leave t current) with
        controller = Controller.cancel_pending t.controller
      ; palette = Some palette
      }
    in
    if not (available t ~width ~height Palette_tile.id)
    then
      { t with
        palette = None
      ; host = Host.with_notice (Host.return t.host) (palette_title ^ " cannot fit in compact layout")
      }
    else
      { t with
        host = Host.focus t.host Palette_tile.id
      ; palette =
          Some (Palette_tile.fit palette ~rows:(minor_rows t ~width ~height Palette_tile.id))
      })
;;

let apply_view_command t ~width ~height (view : View_command.t) =
  match view with
  | Present_buffers buffer_presentation ->
    { t with buffer_presentation; rows = None
      ; animation = Animation.create ~enabled:(Animation.enabled t.animation) }
  | Directory_major | Directory_side ->
    adopt_session_state t (Session.set_directory_placement (session t)
      (if View_command.equal view Directory_major then Major else Side)) ~width ~height
  | Hide_directory -> adopt_session_state t (Session.hide_directory (session t)) ~width ~height
  | Recreate_missing_file -> adopt_session_state t (Session.recreate_current (session t)) ~width ~height
  | Focus_directory ->
    let s = session t in
    let s = if Option.is_none (Session.directory_buffer s) then Session.set_directory_placement s Side
      else Session.focus_directory s (Option.is_none (Session.input_directory s) || Option.is_none (Session.active_id s)) in
    adopt_session_state t s ~width ~height
  | Adjust_directory_size cells ->
    { t with directory_size = Int.clamp_exn (t.directory_size + cells) ~min:16 ~max:500; rows = None
      ; animation = Animation.create ~enabled:(Animation.enabled t.animation) }
  | Toggle_entry_mark | Mark_selection | Unmark_selection | Clear_directory_marks | Open_marked_files
  | Toggle_directory | Open_directory_entry | Directory_parent | Refresh_directory ->
    let session, _, _ = Session.dispatch (session t) [ View view ] in
    adopt_session_state t session ~width ~height
  | Next_tab -> switch_tab t ~width ~height ~direction:1
  | Previous_tab -> switch_tab t ~width ~height ~direction:(-1)
  | Close_tab | Force_close_tab ->
    (match Session.active_id (session t) with
     | None -> t
     | Some id -> fst (close_buffer_state t ~width ~height id ~force:(View_command.equal view Force_close_tab)))
  | Open_palette -> open_palette t ~width ~height
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
  | Focus_history ->
    toggle_focus t ~width ~height History_tile.id ~show:(fun t ->
      { t with history_visible = true })
  | Toggle_history -> { t with history_visible = not t.history_visible }
  | Restart_source when t.source_attached ->
    { t with source_commands = Restart :: t.source_commands }
  | Kill_source when t.source_attached ->
    { t with source_commands = Kill :: t.source_commands }
  | Restart_source | Kill_source -> t
  | Toggle_problems -> { t with problems_visible = not t.problems_visible }
  | Toggle_problems_filter -> { t with problems = Problems_tile.toggle_filter t.problems }
  | Inspect_problems ->
    { t with controller = Controller.update_feedback t.controller Inspect_next }
  | Scroll { scroll; count } -> scroll_view t ~width ~height scroll ~count
  | Toggle_smear ->
    { t with
      animation = Animation.set_enabled t.animation (not (Animation.enabled t.animation))
    }
  | Toggle_hotkey_hints -> { t with hotkey_hints = not t.hotkey_hints }
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

(* What follows a controller step, whether keyed or dispatched: its view commands in
   order, then at most one notification. A keymap notice, which only a keyed step has,
   wins over layout feedback for the last view command. *)
let finish_step t ~width ~height ~controller ~views ~keymap_notice =
  let t =
    List.fold views ~init:{ t with controller } ~f:(fun t view ->
      apply_view_command t ~width ~height view)
  in
  let notification =
    match keymap_notice, List.last views with
    | Some text, _ -> Some (Ches_error.Error.Severity.Warning, "keymap", text, true)
    | None, Some view ->
      (* Layout feedback is transient chatter; history keeps keymap notices only. *)
      Option.map (view_feedback t ~width ~height view) ~f:(fun text ->
        Ches_error.Error.Severity.Info, "workspace", text, false)
    | None, None -> None
  in
  match notification with
  | None -> t
  | Some (severity, source, text, history) ->
    { t with
      controller =
        Controller.update_feedback
          t.controller
          (Notify { source; scope = None; severity; text; history })
    }
;;

let feed t ~width ~height (input : Keymap.Input.t) =
  let session, views, status = Session.handle_input (session t) input in
  let t = adopt_session_state t session ~width ~height in
  let controller = Option.value (Session.active_controller session) ~default:(Controller.with_feedback t.controller (Session.feedback session)) in
  ( finish_step
      { t with session }
      ~width
      ~height
      ~controller
      ~views
      ~keymap_notice:(Keymap.notice (Controller.keymap controller))
  , status )
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
           ; history = false
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
  else if View_id.equal id History_tile.id
  then
    route
      ~content:(History_tile.interpret t.history)
      ~escape:(History_tile.escape t.history)
      ~hint:History_tile.hint
      ~perform:(fun t action ->
        let { History_tile.Outcome.tile; effect; clear } =
          History_tile.perform
            t.history
            (Ches_error.Error.history (Controller.feedback t.controller))
            ~rows
            ~width:cols
            action
        in
        let t = text_effect { t with history = tile } ~source:id effect in
        if clear
        then
          { t with
            controller = Controller.update_feedback t.controller Clear_history
          ; host = Host.with_notice t.host "History cleared; active problems unchanged"
          }
        else t)
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

(* A finished paste for minor view [id], which started it and accepts paste. It is never
   redirected: if [id] is no longer allocated it is dropped with a notice. Each
   adapter that accepts paste takes the text here, beside its keys in {!feed_capture},
   and sanitizes it itself. *)
let paste_capture t ~width ~height id text =
  let title = (Host.spec t.host id).title in
  if not (available t ~width ~height id)
  then pane_notice t ~source:id (sprintf "%s closed; paste dropped" title)
  else (
    match t.palette with
    | Some palette when View_id.equal id Palette_tile.id ->
      { t with
        palette =
          Some
            (Palette_tile.update
               palette
               ~rows:(minor_rows t ~width ~height id)
               (Paste text))
      }
    | Some _ | None -> pane_notice t ~source:id (sprintf "%s: paste unsupported" title))
;;

(* Accepting the palette: close it and return to the document, then dispatch the
   command once through the controller's shared route, as its key binding would. A
   refusal closes it too and says why; nothing runs on another target. *)
let accept_palette t ~width ~height palette =
  let editor = Controller.editor t.controller in
  let context : Ches_palette.Catalog.Context.t option =
    Option.some_if
      (View_id.equal (Ches_palette.Palette.token palette) document_id)
      { Ches_palette.Catalog.Context.mode = Editor.mode editor }
  in
  let refuse text = pane_notice (return_to_document t) ~source:Palette_tile.id text in
  match Ches_palette.Palette.accept palette ~context with
  | No_selection -> { t with host = Host.with_notice t.host "No matching command" }, Controller.Status.Running
  | Target_gone _ -> refuse "The palette's document is gone; nothing ran", Running
  | Unavailable { id; _ } ->
    let title =
      Option.value_map
        (Ches_palette.Catalog.find Ches_palette.Catalog.default id)
        ~default:(Ches_palette.Catalog.Id.to_string id)
        ~f:Ches_palette.Catalog.Entry.title
    in
    refuse (sprintf "%s is unavailable here; nothing ran" title), Running
  | Execute { action; _ } ->
    let t = return_to_document t in
     let session, views, status = Session.dispatch (session t) [ action ] in
     let t = adopt_session_state t session ~width ~height in
    let controller = Option.value (Session.active_controller session) ~default:(Controller.with_feedback t.controller (Session.feedback session)) in
    finish_step { t with session } ~width ~height ~controller ~views ~keymap_notice:None, status
;;

(* A key typed into the open palette. Every character is query text (it accepts text),
   so only Escape, Tab, and Ctrl-c are the host's. *)
let feed_palette t ~width ~height palette key =
  let host, (decision : _ Host.Decision.t) =
    Host.key
      t.host
      key
      ~lookup:(Keymap.lookup (Controller.keymap t.controller))
      ~content:Palette_tile.interpret
      ~escape:None
      ~hint:Palette_tile.hint
  in
  let t = { t with host } in
  match decision with
  | Handled -> t, Controller.Status.Running
  | Return -> return_to_document t, Running
  | Notice text -> { t with host = Host.with_notice t.host text }, Running
  | Workspace view -> apply_view_command t ~width ~height view, Running
  | Content (Event event) ->
    ( { t with
        palette =
          Some
            (Palette_tile.update
               palette
               ~rows:(minor_rows t ~width ~height Palette_tile.id)
               event)
      }
    , Running )
  | Content Accept -> accept_palette t ~width ~height (Palette_tile.palette palette)
;;

let route t ~width ~height key =
  match Host.capturing t.host ~available:(available t ~width ~height) with
  | Some id when View_id.equal id directory_id ->
    (* A directory is a modal document, not a details/palette capture. In
       particular Space, Visual Enter, search and mark bindings use its keymap. *)
    if Key.equal key Tab && not (Mode.equal (Editor.mode (Controller.editor t.controller)) Insert) then
      apply_view_command t ~width ~height Focus_directory, Controller.Status.Running
    else feed t ~width ~height (Key key)
  | Some id when View_id.equal id Palette_tile.id ->
    (match t.palette with
     | Some palette -> feed_palette t ~width ~height palette key
     | None -> return_to_document t, Controller.Status.Running)
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

(* Diagnostic lists wait while Insert lasts (Neovim's [update_in_insert = false]); a
   checker starting or stopping is an event and applies at once. The revision is
   stamped on arrival, so a held unversioned list is behind the edits made since. *)
(* A list for the open document is matched against the text it arrived with. *)
(* The views are not synchronized here: {!receive_all} does it once for a whole batch,
   since fitting the problems view sorts every standing finding. *)
let apply_source t update ~text =
  let t =
    match (update : Ches_error.Error.update) with
    | Diagnostics_received { source; resource; _ } ->
       { t with problems = Problems_tile.applied t.problems ~source ~resource ~text }
    | _ -> t
  in
  { t with controller = Controller.update_feedback t.controller update }
;;

let rec receive t (event : Ches_error.Source_event.t) =
  match event with
  | Owned { resource; generation; event } ->
    (match Session.find_resource (session t) resource with
     | Some (id, _) when Option.equal Int.equal (Session.source_generation t.session id) (Some generation) -> receive t event
     | _ -> t)
  | event ->
  let owner = match event with
    | Diagnostics { resource; _ } -> Session.find_resource (session t) resource
    | _ -> None in
  let editor = Option.map owner ~f:(fun (_, c) -> Controller.editor c) in
  let update =
    Ches_error.Source_event.to_update event ~current_revision:(Option.value_map editor ~default:(-1) ~f:Editor.revision)
  in
  let text = Option.value_map editor ~default:Text_buffer.empty ~f:Editor.text in
  match event with
  | Diagnostics { source; resource; _ } when Option.exists editor ~f:(fun e -> Mode.equal (Editor.mode e) Insert) ->
    let key = source, resource in
    { t with
      held =
        List.filter t.held ~f:(fun (held, _, _) ->
          not ([%equal: string * string] held key))
        @ [ key, update, text ]
    }
  | Diagnostics _ | Started _ | Stopped _ | Unavailable _ -> apply_source t update ~text
  | Owned _ -> assert false
;;

let receive_all t ~width ~height events =
  synchronize (List.fold events ~init:t ~f:receive) ~width ~height
;;

let release_held t ~width ~height =
  let held, ready = List.partition_tf t.held ~f:(fun ((_, resource), _, _) ->
    Option.exists (Session.find_resource (session t) resource) ~f:(fun (_, c) -> Mode.equal (Editor.mode (Controller.editor c)) Insert)) in
    List.fold ready ~init:{ t with held } ~f:(fun t (_, update, text) -> apply_source t update ~text)
    |> synchronize ~width ~height
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
  | Source event -> receive_all t ~width ~height [ event ], Running
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
    and before_history_visible = t.history_visible
    and before_zen = t.zen in
    let before_buffer = Session.context_id t.session in
    let t, status =
      match input with
       | Paste_start ->
          ( { t with host = Host.paste_start t.host ~available:(available t ~width ~height); paste_buffer = Session.context_id t.session }
        , Controller.Status.Running )
      | Paste_end ->
        (match Host.paste_end t.host with
         | host, `Not_pasting -> { t with host }, Running
          | host, `Deliver (owner, text) when View_id.equal owner document_id ->
            if Option.equal Buffer_id.equal t.paste_buffer (Session.context_id t.session) && has_document t
            then feed ~width ~height { t with host } (Paste text)
            else { t with host }, Running
         | host, `Deliver (owner, text) ->
           paste_capture { t with host } ~width ~height owner text, Running
         | host, `Reject (owner, text) -> pane_notice { t with host } ~source:owner text, Running)
      | Key key when Host.pasting t.host -> { t with host = Host.paste_key t.host key }, Running
       | Key key when not (has_document t) ->
         feed t ~width ~height (Key key)
       | Key key -> route ~width ~height t key
      | Animation_tick _ | Resize | Source _ -> assert false
    in
    let t = release_held t ~width ~height in
    let t = refit t ~width ~height in
    let after = cursor_position t ~width ~height in
    let was_active = Animation.active t.animation in
    let animation =
      if (not (Workspace.Prefs.equal before_workspace t.workspace_prefs))
          || not (Option.equal Buffer_id.equal before_buffer (Session.context_id t.session))
         || Bool.(before_problems_visible <> t.problems_visible)
         || Bool.(before_report_visible <> t.report_visible)
         || Bool.(before_history_visible <> t.history_visible)
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

(* Consecutive [Source] inputs, as a frontend delivers a batch of source events, are
   one step: the same result as applying them one by one, with one synchronization. *)
let apply_all t ~width ~height inputs =
  let steps =
    List.group inputs ~break:(fun (a : Input.t) (b : Input.t) ->
      match a, b with
      | Source _, Source _ -> false
      | _ -> true)
  in
  List.fold_until
    steps
    ~init:t
    ~f:(fun t step ->
      let result =
        match step with
        | Source _ :: _ when t.exited -> t, Controller.Status.Exit
        | Source _ :: _ ->
          let t = refit t ~width ~height in
          ( receive_all
              t
              ~width
              ~height
              (List.filter_map step ~f:(function
                 | Input.Source event -> Some event
                 | _ -> None))
          , Controller.Status.Running )
        | [ input ] -> apply t ~width ~height input
        | _ -> assert false
      in
      match result with
      | t, Running -> Continue t
      | t, Exit -> Stop (t, Controller.Status.Exit))
    ~finish:(fun t -> t, Running)
;;

let adopt_session t session ~width ~height =
  release_held (adopt_session_state t session ~width ~height) ~width ~height
;;

let open_file t ~width ~height path =
  Or_error.map (Session.open_or_activate (session t) path) ~f:(fun (session, id) -> adopt_session t session ~width ~height, id)
;;
let activate_buffer t ~width ~height id =
  Or_error.map (Session.activate (session t) id) ~f:(fun session -> adopt_session t session ~width ~height)
;;
let show_directory ?select t ~width ~height path =
  Or_error.map (Session.show_directory ?select (session t) path) ~f:(fun session -> adopt_session t session ~width ~height)
;;
let close_buffer t ~width ~height id ~force =
  let t, closed = close_buffer_state t ~width ~height id ~force in
  release_held t ~width ~height, closed
;;
let close_current t ~width ~height ~force =
  match Session.active_id (session t) with
  | None -> t, false
  | Some id -> close_buffer t ~width ~height id ~force
;;
let save_all t ~width ~height =
  let session, results = Session.save_all (session t) in
  adopt_session t session ~width ~height, results
;;
let quit_session t ~width ~height ~force =
  let session, status = Session.quit (session t) ~force in
  adopt_session t session ~width ~height, status
;;
