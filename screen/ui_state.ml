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
    | File_picker_snapshot of Ches_file_picker.Model.Discovery.t
    | File_picker_update of Ches_file_picker.Model.Discovery.Update.t
    | File_preview of Ches_file_preview_model.Model.snapshot
    | File_picker_work of Ches_file_picker.Model.Discovery.request
    | File_picker_accept of View_id.t Ches_file_picker.Model.Request.t
    | Content_picker_accept of (View_id.t Ches_content_picker.Model.intent [@sexp.opaque])
    | Line_picker_work of int
    | Content_picker_snapshot of (Ches_content_picker.Model.snapshot [@sexp.opaque])
  [@@deriving sexp_of]
end

type t =
  { controller : Controller.t
  ; session : Session.t
  ; scrolls : Scroll.t Buffer_id.Map.t
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
  ; views : View_registry.t
  (** Problems, the demo report (installed only by [--demo-report]), history, and any
      further installed views, with their placements. *)
  ; tabs : Tab_strip.t (** View tabs' order among the file tabs, and the active one. *)
  ; split : Workspace.Major_split.t (** Requested side and share of the split view. *)
  ; palette : Palette_tile.t option (** Open, and then focused, or closed. *)
  ; palette_origin : View_id.t option
  (** The registered view the palette was opened over: its local commands are listed
      first, and it is not left until the palette closes. *)
  ; help : Help_tile.t option (** The [?] float, over its origin view. *)
  ; confirm : Confirm_tile.t option (** A view's pending confirmation, over it. *)
  ; prompt : Prompt_tile.t option (** A view's pending prompt, over it. *)
  ; file_picker : View_id.t File_picker_tile.t option
  ; file_picker_release : unit -> unit
  ; file_picker_return : View_id.t
  ; file_requests : View_id.t Ches_file_picker.Model.Request.t list
  ; file_picker_activation : bool
  ; content_picker_activation : bool
  ; line_picker : Line_picker_tile.t option
  ; line_generation : int
  ; line_picker_return : View_id.t
  ; content_picker : View_id.t Content_picker_tile.t option
  ; content_picker_release : unit -> unit
  ; content_picker_return : View_id.t
  ; content_requests : View_id.t Ches_content_picker.Model.intent list
  ; scroll : Scroll.t
  ; rows : int option
  (** Text rows the scroll was last fitted for: when they change, the fit fills the
      viewport (see {!Scroll.fit}). *)
  ; animation : Animation.t
  ; animation_time : Time_ns.t option
  ; fitted_dimensions : (int * int) option
  ; exited : bool
  ; held : ((string * string) * Ches_error.Error.update * Text_buffer.t) list
  (** Diagnostic snapshots that arrived during Insert, newest per (source, resource),
      in arrival order, with the text at arrival; applied when Insert ends. *)
  ; source_attached : bool (** A diagnostic source runs ([--synthetic-checker]). *)
  ; sent_revisions : (int * int) Buffer_id.Map.t
  ; source_commands : Ches_error.Source_request.t list
  (** Restart/kill requests not yet taken, newest first. *)
  }

let document_id = View_id.of_string "document"
let status_id = View_id.of_string "status"
let directory_id = View_id.of_string "directory"
let demo_report_unavailable = "Demo report unavailable; launch with --demo-report"

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
  ?(views = [])
  controller
  =
  let placement = if tiles_visible then View_registry.Placement.Band else Hidden in
  let views =
    View_registry.create
      ([ View_registry.Entry.install ~placement Problems_tile.adapter Problems_tile.empty
       ; (match report with
          | Some items ->
            View_registry.Entry.install ~placement Report_tile.adapter (Report_tile.create items)
          | None ->
            View_registry.Entry.unavailable Report_tile.id ~title:Report_tile.spec.title
              ~notice:demo_report_unavailable)
       ; View_registry.Entry.install ~placement History_tile.adapter History_tile.empty
       ]
       @ views)
  in
  let workspace_prefs =
    Option.value workspace_prefs
      ~default:{ Workspace.Prefs.default with status_visible = tiles_visible }
  in
  let session = Session.create ?directory_config ~cell_width:Cell_map.width controller in
  let controller = Option.value_exn (Session.active_controller session) in
  { controller
  ; session
  ; scrolls = Buffer_id.Map.empty
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
        ([ Ches_tile.Spec.primary document_id ~title:"Document"
         ; Ches_tile.Spec.companion status_id ~title:"Status"
         ]
         @ View_registry.specs views
         @ [ Palette_tile.spec
           ; File_picker_tile.spec
           ; Line_picker_tile.spec
           ; Content_picker_tile.spec
           ; Help_tile.spec
           ; Confirm_tile.spec
           ; Prompt_tile.spec
           ; Ches_tile.Spec.read_only_text directory_id ~title:"Directory"
           ])
  ; views
  ; tabs = Tab_strip.empty
  ; split = Workspace.Major_split.default
  ; palette = None
  ; palette_origin = None
  ; help = None
  ; confirm = None
  ; prompt = None
  ; file_picker = None
  ; file_picker_activation = false
  ; content_picker_activation = false
  ; file_picker_release = (fun () -> ())
  ; file_picker_return = document_id
  ; file_requests = []
  ; line_picker = None
  ; line_generation = 0
  ; line_picker_return = document_id
  ; content_picker = None
  ; content_picker_release = (fun () -> ())
  ; content_picker_return = document_id
  ; content_requests = []
  ; scroll = Scroll.zero
  ; rows = None
  ; animation = Animation.create ~enabled:smear_enabled
  ; animation_time = None
  ; fitted_dimensions = None
  ; exited = false
  ; held = []
  ; source_attached
  ; sent_revisions = Buffer_id.Map.empty
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
let views t = t.views

let view_visible t id =
  Option.exists (View_registry.placement t.views id) ~f:(fun placement ->
    not (View_registry.Placement.equal placement Hidden))
;;

let split t = t.split
let view_title t id = (Host.spec t.host id).title

let tab_entries t =
  Tab_strip.entries t.tabs
    ~files:(List.map (Session.buffers t.session) ~f:fst)
    ~views:(View_registry.tabs t.views)
;;

(* The active view tab, while it is still placed as a tab. *)
let active_tab_view t =
  Option.filter (Tab_strip.active t.tabs) ~f:(fun id ->
    Option.exists (View_registry.placement t.views id) ~f:(fun placement ->
      View_registry.Placement.equal placement Tab))
;;

let active_tab t : Tab_strip.Entry.t option =
  match active_tab_view t with
  | Some id -> Some (View id)
  | None -> Option.map (Session.active_id t.session) ~f:(fun id -> Tab_strip.Entry.File id)
;;

(* Show the session's active file tab (or directory) instead of a view tab. *)
let file_tab t = { t with tabs = Tab_strip.activate t.tabs None }

let tab_items t =
  let files = Open_buffers.of_session (session t) in
  let active_view = active_tab_view t in
  List.filter_map (tab_entries t) ~f:(function
    | File id ->
      List.find files ~f:(fun file -> Buffer_id.equal file.id id)
      |> Option.map ~f:(fun file ->
        let item = Tab_strip.Item.of_file file in
        { item with active = item.active && Option.is_none active_view })
    | View id ->
      Some
        { Tab_strip.Item.label = view_title t id
        ; active = Option.exists active_view ~f:(View_id.equal id)
        ; modified = false
        ; missing = false
        })
;;

(* Problems and history are always installed (see [create]). *)
let problems_tile t = Option.value_exn (View_registry.find t.views Problems_tile.key)
let history_tile t = Option.value_exn (View_registry.find t.views History_tile.key)
let report t = View_registry.find t.views Report_tile.key
let problems_visible t = view_visible t Problems_tile.id
let problems_current_document t = Problems_tile.current_document (problems_tile t)
let report_visible t = view_visible t Report_tile.id
let history_visible t = view_visible t History_tile.id
let palette t = t.palette
let help t = t.help
let confirm t = t.confirm
let prompt t = t.prompt
let file_picker t = t.file_picker
let file_picker_visible_stamp t = Option.map t.file_picker ~f:File_picker_tile.visible_stamp
let content_picker t = t.content_picker
let take_content_requests t = { t with content_requests = [] }, List.rev t.content_requests
let line_picker t = t.line_picker
let line_picker_generation t = t.line_generation

let take_file_requests t = { t with file_requests = [] }, List.rev t.file_requests
;;
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
    let session, _ = Session.take_source_changes session in
    let controller = Option.value (Session.active_controller session) ~default:t.controller in
    { t with session; controller; source_commands = [] }, [])
  else (
    let session, saved = Session.take_saved (session t) in
    let session, closed = Session.take_closed session in
    let session, changes = Session.take_source_changes session in
    let sent_revisions, document = List.fold changes ~init:(t.sent_revisions, []) ~f:(fun (sent, requests) (id, current) ->
      match current with
      | None -> Map.remove sent id, requests
      | Some (generation, controller) ->
        let editor = Controller.editor controller in
        let previous = Map.find sent id in
        let sent = Map.set sent ~key:id ~data:(generation, Editor.revision editor) in
        match Editor.path editor with
        | None -> sent, requests
        | Some resource ->
          let same_lifetime = Option.exists previous ~f:(fun (old, _) -> old = generation) in
          let opened = if not same_lifetime then [ Ches_error.Source_request.Document_opened { resource; generation } ] else [] in
          let changed = if Option.equal Poly.equal previous (Some (generation, Editor.revision editor)) then [] else
            [ Ches_error.Source_request.Document_changed { resource; text = Text_buffer.to_string (Editor.text editor); revision = Editor.revision editor } ] in
          sent, List.rev_append (opened @ changed) requests) in
    let document = List.rev document in
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
     && List.length (tab_entries t) > 1
     && not t.zen && allocation.width > 0 && allocation.height >= 3
  then Some { allocation with height = 1 }
  else None
;;

let directory_rect ?(buffers_in_status = false) t ~(allocation : Geometry.Rect.t) =
  let allocation = match tab_rect ~buffers_in_status t ~allocation with None -> allocation | Some _ ->
    { allocation with y = allocation.y + 1; height = allocation.height - 1 } in
  if Option.is_some (Session.input_directory t.session) && Option.is_none (active_tab_view t)
     && allocation.height >= 2 && allocation.width > 0
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
  let minors = if t.zen then [] else View_registry.band t.views in
  Workspace.allocate
    ~minors
    ?split:(if t.zen then None
      else Option.map (View_registry.split t.views) ~f:(fun id -> id, t.split))
    ?side:(Option.bind (Session.directory_presentation t.session) ~f:(fun p ->
      Option.some_if (Poly.equal p.placement Side && not t.zen && Option.is_some (Session.active_id t.session))
        (directory_id, t.directory_size)))
    (if t.zen then { prefs with status_visible = false } else prefs)
    ~allocation:{ Geometry.Rect.x = 0; y = 0; width; height }
;;

let buffers_in_status_in t (workspace : Workspace.t) =
  View_command.Buffer_presentation.equal t.buffer_presentation Status_rows
  && Option.exists workspace.status ~f:(fun pane ->
    let content = (Tile_shell.layout Tile_shell.Policy.status pane.rect).content in
    content.width > 0 && content.height > 0)
;;

let buffers_in_status t ~width ~height = buffers_in_status_in t (workspace t ~width ~height)

(* The active view tab's shell: the editor area below the tab strip, above any
   compact feedback row, like the document it covers. *)
let tab_view_layout t (workspace : Workspace.t) =
  let allocation = workspace.document.rect in
  let allocation =
    match tab_rect ~buffers_in_status:(buffers_in_status_in t workspace) t ~allocation with
    | None -> allocation
    | Some _ -> { allocation with y = allocation.y + 1; height = allocation.height - 1 }
  in
  let feedback = if workspace.reserve_status_row then 1 else 0 in
  let rect = { allocation with height = allocation.height - feedback } in
  Option.some_if (rect.width > 0 && rect.height > 0)
    (Tile_shell.layout Tile_shell.Policy.minor rect)
;;

let palette_placement ~width ~height =
  Floating.layout
    ~bounds:{ Geometry.Rect.x = 0; y = 0; width; height }
    ~preferred:{ width = 80; height = 14 }
    ~minimum:{ width = 14; height = 4 }
    ~policy:{ Tile_shell.Policy.minor with min_content_height = 2 }
;;

let palette_layout t ~width ~height =
  Option.bind t.palette ~f:(fun _ -> palette_placement ~width ~height)
;;

let picker_placement ~width ~height =
  Floating.layout
    ~bounds:{ Geometry.Rect.x = 0; y = 0; width; height }
    ~preferred:{ width = 80; height = 14 }
    ~minimum:{ width = 14; height = 5 }
    ~policy:{ Tile_shell.Policy.minor with min_content_height = 3 }
;;

let file_picker_layout t ~width ~height =
  Option.bind t.file_picker ~f:(fun _ ->
    Floating.place
      ~bounds:{ Geometry.Rect.x = 0; y = 0; width; height }
      ~preferred:{ width = (if width >= 104 then 175 else 80); height = 40 }
      ~minimum:{ width = 14; height = 5 }
    |> Option.map ~f:(fun rect ->
      let top_margin = if height - rect.height >= 2 then 1 else 0 in
      let rect = { rect with y = Int.max top_margin (rect.y - 2) } in
      Tile_shell.layout { Tile_shell.Policy.minor with min_content_height = 3 } rect))
;;

let line_picker_layout t ~width ~height =
  Option.bind t.line_picker ~f:(fun _ -> picker_placement ~width ~height)
;;

let content_picker_layout t ~width ~height =
  Option.bind t.content_picker ~f:(fun _ -> picker_placement ~width ~height)
;;

let help_placement help ~width ~height =
  Floating.layout
    ~bounds:{ Geometry.Rect.x = 0; y = 0; width; height }
    ~preferred:(Help_tile.preferred_size help)
    ~minimum:{ width = 14; height = 3 }
    ~policy:{ Tile_shell.Policy.minor with min_content_height = 1 }
;;

let help_layout t ~width ~height =
  Option.bind t.help ~f:(fun help -> help_placement help ~width ~height)
;;

let ask_placement ~preferred ~(minimum : Floating.Size.t) ~width ~height =
  Floating.layout
    ~bounds:{ Geometry.Rect.x = 0; y = 0; width; height }
    ~preferred
    ~minimum
    ~policy:{ Tile_shell.Policy.minor with min_content_height = minimum.height - 2 }
;;

let confirm_placement confirm ~width ~height =
  ask_placement ~preferred:(Confirm_tile.preferred_size confirm) ~minimum:Confirm_tile.minimum
    ~width ~height
;;

let prompt_placement ~width ~height =
  ask_placement ~preferred:Prompt_tile.preferred_size ~minimum:Prompt_tile.minimum ~width ~height
;;

let confirm_layout t ~width ~height =
  Option.bind t.confirm ~f:(fun confirm -> confirm_placement confirm ~width ~height)
;;

let prompt_layout t ~width ~height =
  Option.bind t.prompt ~f:(fun _ -> prompt_placement ~width ~height)
;;

let effective_floating floating t ~width ~height =
  match floating with
  | Some _ -> floating
  | None ->
    (match t.content_picker with
     | Some _ -> Some (Content_picker_tile.id, content_picker_layout t ~width ~height)
     | None -> match t.line_picker, t.file_picker with
      | Some _, _ -> Some (Line_picker_tile.id, line_picker_layout t ~width ~height)
      | None, Some _ -> Some (File_picker_tile.id, file_picker_layout t ~width ~height)
      | None, None ->
        (match t.palette with
         | Some _ -> Some (Palette_tile.id, palette_layout t ~width ~height)
         | None ->
           (match t.help, t.confirm, t.prompt with
            | Some _, _, _ -> Some (Help_tile.id, help_layout t ~width ~height)
            | None, Some _, _ -> Some (Confirm_tile.id, confirm_layout t ~width ~height)
            | None, None, Some _ -> Some (Prompt_tile.id, prompt_layout t ~width ~height)
            | None, None, None -> None)))
;;

(* A supplied floating identity overrides its tiled placement, including when
   resize makes its layout unavailable. Otherwise resolve the live palette. A view
   tab has a layout only while active; a split or band view, while allocated. *)
let view_layout_in ?floating t (workspace : Workspace.t) id =
  if View_id.equal id document_id
  then None
  else match floating with
  | Some (floating_id, layout) when View_id.equal id floating_id -> layout
  | _ ->
    if View_id.equal id status_id
    then Option.map workspace.status ~f:(fun pane ->
      Tile_shell.layout Tile_shell.Policy.status pane.rect)
    else if Option.exists (active_tab_view t) ~f:(View_id.equal id)
    then tab_view_layout t workspace
    else
      Option.map (Workspace.minor workspace id) ~f:(fun pane ->
        Tile_shell.layout Tile_shell.Policy.minor pane.rect)
;;

let view_layout ?floating t ~width ~height id =
  let floating = effective_floating floating t ~width ~height in
  view_layout_in ?floating t (workspace t ~width ~height) id
;;

let view_available ?floating t ~width ~height =
  let floating = effective_floating floating t ~width ~height in
  let workspace = workspace t ~width ~height in
  fun id ->
    View_id.equal id document_id
    || Option.is_some (view_layout_in ?floating t workspace id)
;;

let available t ~width ~height = view_available t ~width ~height

let side_layout t ~width ~height = view_layout t ~width ~height directory_id

let input_allocation t ~width ~height =
  match Session.input_directory t.session, side_layout t ~width ~height with
  | Some _, Some layout -> layout.content, false
  | _ -> let w = workspace t ~width ~height in w.document.rect, w.reserve_status_row
;;

let focused_view ?floating t ~width ~height =
  Host.focused t.host ~available:(view_available ?floating t ~width ~height)

let cursor_owner ?floating t ~width ~height =
  Option.filter (Host.cursor_owner t.host ~available:(view_available ?floating t ~width ~height))
    ~f:(fun id -> not (View_id.equal id document_id) || has_document t)
;;

let surface t ~directory =
  let session = Session.surface (session t) ~directory in
  let id = Session.context_id session in
  let scroll = if Option.equal Buffer_id.equal id (Session.context_id t.session) then t.scroll else
    Option.value (Option.bind id ~f:(Map.find t.scrolls)) ~default:Scroll.zero in
  { t with session; controller = Option.value (Session.active_controller session) ~default:t.controller
    ; scroll; rows = None; hide_tabs = directory
    ; tabs = (if directory then Tab_strip.activate t.tabs None else t.tabs)
    ; prefs = (if directory then { t.prefs with centered = false; left_padding = 0 } else t.prefs) }
;;

let problems_focused t ~width ~height =
  View_id.equal (focused_view t ~width ~height) Problems_tile.id
;;

let minor_layout t ~width ~height id =
  if View_id.equal id status_id || View_id.equal id document_id
  then None
  else view_layout_in t (workspace t ~width ~height) id
;;

(* A minor view's content viewport: what it scrolls by and wraps to. *)
let minor_rows t ~width ~height id =
  Option.value_map (view_layout t ~width ~height id) ~default:1
    ~f:(fun layout -> Int.max 1 layout.content.height)
;;

let minor_width t ~width ~height id =
  Option.value_map (view_layout t ~width ~height id) ~default:width
    ~f:(fun layout -> layout.content.width)
;;

let path t = Editor.path (Controller.editor t.controller)
let document t = Problems_tile.document (problems_tile t) (Controller.editor t.controller)

let fitted_problems t ~width ~height =
  Problems_tile.fit (problems_tile t) (Controller.feedback t.controller) ~document:(document t)
    ~rows:(minor_rows t ~width ~height Problems_tile.id)
    ~width:(minor_width t ~width ~height Problems_tile.id)
;;

let problem_navigation t ~width ~height =
  Problems_tile.selection (fitted_problems t ~width ~height)
;;

let selected_problem t ~width ~height =
  Problems_tile.selected (problems_tile t) (Controller.feedback t.controller) ~document:(document t)
    ~rows:(minor_rows t ~width ~height Problems_tile.id)
;;

(* A registered view's open read-only text, if any. *)
let text_view t id = View_registry.text_view t.views id

(* Where minor view [id]'s adapter wants the cursor in its [content] area. The palette
   puts a bar after its query; a view with open read-only text puts a block on its text
   cursor; others want none. *)
let cursor_intent t id ~(content : Geometry.Rect.t) : Ches_tile.Cursor.t option =
  if View_id.equal id Palette_tile.id
  then Option.map t.palette ~f:(Palette_tile.cursor ~width:content.width)
  else if View_id.equal id File_picker_tile.id
  then Option.map t.file_picker ~f:(File_picker_tile.cursor ~width:content.width)
  else if View_id.equal id Line_picker_tile.id
  then Option.map t.line_picker ~f:(Line_picker_tile.cursor ~width:content.width)
  else if View_id.equal id Content_picker_tile.id
  then Option.map t.content_picker ~f:(Content_picker_tile.cursor ~width:content.width)
  else if View_id.equal id Prompt_tile.id
  then Option.map t.prompt ~f:(Prompt_tile.cursor ~width:content.width)
  else
    Option.map (text_view t id) ~f:(fun view ->
      let view = Ches_tile.Text_view.fit view ~width:content.width ~rows:content.height in
      let row, column = Ches_tile.Text_view.cursor_cell view ~width:content.width in
      { Ches_tile.Cursor.row = row - Ches_tile.Text_view.top view; column; shape = Block })
;;

let supporting_cursor ?floating t ~width ~height =
  match cursor_owner ?floating t ~width ~height with
  | None -> None
  | Some id when View_id.equal id document_id -> None
  | Some id ->
    Option.bind (view_layout ?floating t ~width ~height id) ~f:(fun (layout : Tile_shell.Layout.t) ->
      let content = layout.content in
      Option.bind (cursor_intent t id ~content) ~f:(fun { row; column; shape } ->
        Option.some_if
          (column >= 0 && column < content.width && row >= 0 && row < content.height)
          (content.x + column, content.y + row, shape)))
;;

let problem_details t = Problems_tile.details (problems_tile t)
let problem_detail_top t = Problems_tile.detail_top (problems_tile t)
let capture_notice t = Host.notice t.host

let capture_pending t =
  match Host.pending t.host with
  | [] -> None
  | keys -> Some (String.concat ~sep:" " (List.map keys ~f:Key.to_string_hum))
;;

let ask_origin t =
  Option.first_some
    (Option.map t.confirm ~f:Confirm_tile.origin)
    (Option.map t.prompt ~f:Prompt_tile.origin)
;;

(* Close the question float, leaving its view's question pending. *)
let close_ask t =
  let host = Host.invalidate_paste t.host Prompt_tile.id in
  { t with confirm = None; prompt = None; host }
;;

(* Close a view's capture-local state (details) when it stops being focused. *)
let leave t id =
  let t = { t with host = Host.invalidate_paste t.host id } in
  if View_registry.installed t.views id
  then { t with views = View_registry.leave t.views id }
  else if View_id.equal id Palette_tile.id
  then (* Leaving closes the palette and discards its query; nothing runs. *)
    { t with palette = None; palette_origin = None }
  else if View_id.equal id Help_tile.id
  then { t with help = None }
  else if View_id.equal id Confirm_tile.id || View_id.equal id Prompt_tile.id
  then (* Leaving a question unanswered withdraws it: nothing runs. *)
    { (close_ask t) with
      views =
        Option.fold (ask_origin t) ~init:t.views ~f:View_registry.withdraw
    }
  else if View_id.equal id File_picker_tile.id
  then (
    Option.iter t.file_picker ~f:(fun picker ->
      File_picker_tile.cancel picker ~release:t.file_picker_release);
    { t with file_picker = None; file_picker_release = (fun () -> ()) })
  else if View_id.equal id Line_picker_tile.id
  then (
    Option.iter t.line_picker ~f:(fun picker -> Line_picker_tile.cancel picker ~release:(fun () -> ()));
    { t with line_picker = None })
  else if View_id.equal id Content_picker_tile.id
  then (
    Option.iter t.content_picker ~f:(fun picker ->
      Content_picker_tile.cancel picker ~release:t.content_picker_release);
    { t with content_picker = None; content_picker_release = (fun () -> ()) })
  else t
;;

(* Every view with state to leave: the registered views, then the floats. *)
let leave_ids t =
  View_registry.ids t.views
  @ [ Palette_tile.id; File_picker_tile.id; Line_picker_tile.id; Content_picker_tile.id; Help_tile.id
    ; Confirm_tile.id; Prompt_tile.id ]
;;

let close_content_picker t ~width ~height =
  let previous = t.content_picker_return in
  let t = leave t Content_picker_tile.id in
  let host = Host.return t.host in
  let host = if available t ~width ~height previous then Host.focus host previous else host in
  { t with host; controller = Controller.cancel_pending t.controller }
;;

let close_file_picker t ~width ~height =
  let previous = t.file_picker_return in
  let t = leave t File_picker_tile.id in
  let host = Host.return t.host in
  let host = if available t ~width ~height previous then Host.focus host previous else host in
  { t with host; controller = Controller.cancel_pending t.controller }
;;

let close_line_picker t ~width ~height =
  let previous = t.line_picker_return in
  let t = leave t Line_picker_tile.id in
  let host = Host.return t.host in
  let host = if available t ~width ~height previous then Host.focus host previous else host in
  { t with host; controller = Controller.cancel_pending t.controller }
;;

(* Back to the editor area's input owner: a focused side directory, else the active
   view tab, which stands in for the document while it is shown. *)
let return_to_document t =
  let t = List.fold (leave_ids t) ~init:t ~f:leave in
  { t with
    host = (let host = Host.return t.host in
      if Option.is_some (Session.input_directory t.session)
         && Option.is_some (Session.active_id t.session)
         && Option.exists (Session.directory_presentation t.session) ~f:(fun p -> Poly.equal p.placement Side)
      then Host.focus host directory_id
      else Option.value_map (active_tab_view t) ~default:host ~f:(Host.focus host))
  ; animation = Animation.create ~enabled:(Animation.enabled t.animation)
  ; controller = Controller.cancel_pending t.controller
  }
;;

(* Closing help returns to the view it describes, which it never left, or to the
   document when that view is no longer available. *)
let close_help t ~width ~height =
  let origin = Option.map t.help ~f:Help_tile.origin in
  let t = leave t Help_tile.id in
  match origin with
  | Some origin when available t ~width ~height origin ->
    { t with host = Host.focus t.host origin }
  | Some _ | None -> return_to_document t
;;

(* A question float that lost its room or its view closes unanswered: the view's
   question is withdrawn, and focus returns to the view or the document. *)
let withdraw_ask t ~width ~height =
  let lost =
    match t.confirm, t.prompt with
    | Some confirm, _ ->
      Some (Confirm_tile.title confirm, Option.is_none (confirm_layout t ~width ~height))
    | None, Some prompt ->
      Some (Prompt_tile.title prompt, Option.is_none (prompt_layout t ~width ~height))
    | None, None -> None
  in
  match lost, ask_origin t with
  | Some (title, no_room), Some origin
    when no_room || not (available t ~width ~height origin) ->
    let t = leave t (if Option.is_some t.confirm then Confirm_tile.id else Prompt_tile.id) in
    let t =
      if available t ~width ~height origin
      then { t with host = Host.focus t.host origin }
      else return_to_document t
    in
    { t with host = Host.with_notice t.host (sprintf "%s closed; nothing ran" title) }
  | _ -> t
;;

(* Fit each minor view's state to its viewport and source. When the source changes
   the text of open details, say so: the view never retargets a selection silently. *)
let synchronize t ~width ~height =
  let t =
    if Option.is_some t.content_picker && Option.is_none (content_picker_layout t ~width ~height)
    then close_content_picker t ~width ~height else t in
  Option.iter t.content_picker ~f:(fun picker ->
    Content_picker_tile.fit picker ~rows:(minor_rows t ~width ~height Content_picker_tile.id));
  Option.iter t.line_picker ~f:(fun picker ->
    ignore (Line_picker_tile.validate picker t.controller : bool));
  let t =
    if Option.is_some t.line_picker && Option.is_none (line_picker_layout t ~width ~height)
    then close_line_picker t ~width ~height else t
  in
  Option.iter t.line_picker ~f:(fun picker ->
    Line_picker_tile.fit picker ~rows:(minor_rows t ~width ~height Line_picker_tile.id));
  let t =
    if Option.is_some t.file_picker && Option.is_none (file_picker_layout t ~width ~height)
    then close_file_picker t ~width ~height
    else t
  in
  Option.iter t.file_picker ~f:(fun picker ->
    File_picker_tile.fit picker ~rows:(minor_rows t ~width ~height File_picker_tile.id));
  let t =
    match t.help with
    | Some help
      when Option.is_none (help_layout t ~width ~height)
           || not (available t ~width ~height (Help_tile.origin help)) ->
      close_help t ~width ~height
    | Some _ | None -> t
  in
  let t = withdraw_ask t ~width ~height in
  (* Suppressed side placement keeps its request/buffer, but must never retain
     invisible input focus. With no files, the directory remains the major surface. *)
  let t = if Option.is_some (Session.input_directory t.session)
      && Option.is_some (Session.active_id t.session)
      && Option.exists (Session.directory_presentation t.session) ~f:(fun p -> Poly.equal p.placement Side)
      && Option.is_none (side_layout t ~width ~height)
    then
      let old = Session.context_id t.session in
      let scrolls = Option.value_map old ~default:t.scrolls ~f:(fun id -> Map.set t.scrolls ~key:id ~data:t.scroll) in
      let session = Session.focus_directory (session t) false in
      let scroll = Option.value (Option.bind (Session.context_id session) ~f:(Map.find scrolls)) ~default:Scroll.zero in
      { (return_to_document t) with session; controller = Option.value_exn (Session.active_controller session)
        ; scrolls; scroll; rows = None; paste_buffer = None }
    else t in
  let ids = View_registry.ids t.views in
  let before = List.map ids ~f:(text_view t) in
  let t =
    { t with
      views =
        View_registry.fit t.views t.controller ~viewport:(fun id ->
          minor_rows t ~width ~height id, minor_width t ~width ~height id)
    ; palette =
        Option.map t.palette
          ~f:(Palette_tile.fit ~rows:(minor_rows t ~width ~height Palette_tile.id))
    }
  in
  let after = List.map ids ~f:(text_view t) in
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
  let t =
    match Host.reconcile t.host ~available:(available t ~width ~height) with
    | _, `Kept -> t
    | _, `Returned _ -> return_to_document t
  in
  (* The hidden document never owns input while a view tab covers it. *)
  match active_tab_view t with
  | Some id
    when View_id.equal (focused_view t ~width ~height) document_id
         && available t ~width ~height id -> { t with host = Host.focus t.host id }
  | Some _ | None -> t
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
(* A session change that shows a file or a major directory also shows it instead of
   the active view tab: another active file, a newly presented major directory, or
   (unless [keep_view_tab], for focus moves) a directory giving up input. *)
let adopt_session_state ?(keep_view_tab = false) t session ~width ~height =
  let major_directory s =
    Option.is_some (Session.input_directory s)
    && Option.exists (Session.directory_presentation s) ~f:(fun p -> Poly.equal p.placement Major)
  in
  let t =
    if (not (Option.equal Buffer_id.equal (Session.active_id t.session) (Session.active_id session)))
       || (major_directory session && not (major_directory t.session))
       || ((not keep_view_tab)
           && Option.is_some (Session.input_directory t.session)
           && Option.is_none (Session.input_directory session))
    then file_tab t
    else t
  in
  let retired = if Session.same_file_lifetimes t.session session then [] else
    List.filter_map (Session.buffers t.session) ~f:(fun (id, controller) ->
    if Option.equal Int.equal (Session.source_generation t.session id) (Session.source_generation session id)
    then None else Editor.path (Controller.editor controller)) in
  let t = { t with held = List.filter t.held ~f:(fun ((_, resource), _, _) ->
    not (List.mem retired (Session.normalize t.session resource) ~equal:String.equal))
    ; views = View_registry.map t.views Problems_tile.key ~f:(fun problems ->
        List.fold retired ~init:problems ~f:Problems_tile.forget_resource) } in
  let previous = Session.context_id t.session in
  let changed = not (Option.equal Buffer_id.equal previous (Session.context_id session)) in
  let placement_changed = not (Option.equal Poly.equal
    (Option.map (Session.directory_presentation t.session) ~f:(fun p -> p.placement))
    (Option.map (Session.directory_presentation session) ~f:(fun p -> p.placement))) in
  let tabs_changed = not (Bool.equal
    (Session.buffer_count t.session > 1)
    (Session.buffer_count session > 1)) in
  let scrolls = match previous with
    | None -> t.scrolls
    | Some id -> Map.set t.scrolls ~key:id ~data:t.scroll in
  let scrolls = if Session.same_buffer_membership t.session session then scrolls else
    Map.filter_keys scrolls ~f:(Session.has_buffer session) in
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
    let scroll = Option.value (Option.bind (Session.context_id session) ~f:(Map.find scrolls)) ~default:Scroll.zero in
    { (return_to_document t) with scroll; rows = None; paste_buffer = None
      ; animation = Animation.create ~enabled:(Animation.enabled t.animation) } in
  let t = synchronize t ~width ~height in
  if Option.is_some (Session.input_directory t.session) && Option.is_some (side_layout t ~width ~height)
      && Option.is_none t.palette
      && Option.is_none t.file_picker && Option.is_none t.line_picker
      && Option.is_none t.content_picker && Option.is_none t.help
      && Option.is_none t.confirm && Option.is_none t.prompt
  then { t with host = Host.focus t.host directory_id }
  else t
;;

let close_buffer_state t ~width ~height id ~force =
  let session = session t in
  let resource = Option.bind (Session.find session id) ~f:(fun c -> Editor.path (Controller.editor c)) in
  let session, closed = Session.close_buffer session id ~force in
  let t = { t with held = List.filter t.held ~f:(fun ((_, resource), _, _) -> Option.is_some (Session.find_resource session resource)) } in
  let t = if not closed then t else Option.value_map resource ~default:t ~f:(fun resource ->
    { t with views = View_registry.map t.views Problems_tile.key ~f:(fun problems ->
        Problems_tile.forget_resource problems resource) }) in
  adopt_session_state t session ~width ~height, closed
;;

(* Leave an active view tab for the active file tab, returning focus there. *)
let show_file_tab t =
  if Option.is_some (active_tab_view t) then return_to_document (file_tab t) else t
;;

(* Activate view tab [id] and focus it, leaving the view focused before. *)
let show_view_tab t ~width ~height id =
  let current = focused_view t ~width ~height in
  let t = if View_id.equal current id then t else leave t current in
  { t with
    tabs = Tab_strip.activate t.tabs (Some id)
  ; host = Host.focus t.host id
  ; controller = Controller.cancel_pending t.controller
  ; rows = None
  }
;;

(* File and view tabs cycle together, wrapping in strip order. From no active entry
   (a directory without files), forward starts at the first. *)
let switch_tab t ~width ~height ~direction =
  let entries = tab_entries t in
  let count = List.length entries in
  if count = 0
  then t
  else (
    let index =
      Option.bind (active_tab t) ~f:(fun active ->
        List.findi entries ~f:(fun _ entry -> Tab_strip.Entry.equal entry active))
      |> Option.map ~f:fst
    in
    let target =
      match index with
      | Some index -> List.nth_exn entries ((index + direction + count) % count)
      | None -> if direction > 0 then List.hd_exn entries else List.last_exn entries
    in
    match target with
    | View id -> show_view_tab t ~width ~height id
    | File target ->
      adopt_session_state (show_file_tab t) (Session.activate (session t) target |> Or_error.ok_exn) ~width ~height)
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
    , Cell_layout.Index.cursor_span
        (Text_buffer.line_layout text ~width:Cell_map.width line)
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

let minor_cursor ?floating t ~width ~height =
  if View_id.equal (focused_view ?floating t ~width ~height) directory_id then
    Option.map (cursor_position t ~width ~height) ~f:(fun (x, y) -> x, y, Ches_tile.Cursor.Shape.Block)
  else supporting_cursor ?floating t ~width ~height
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
  | Toggle_problems_filter
  | Toggle_view _
  | Focus_view _
  | Place_view _
  | Focus_other_pane
  | Swap_split
  | Adjust_split _
  | Run_view_command _
  | Restart_source
  | Kill_source
  | Scroll _
  | Toggle_smear
  | Toggle_status
  | Toggle_hotkey_hints
  | Position_status _
  | Adjust_status_size _
  | Toggle_zen
   | Open_palette | Open_line_picker | Open_file_picker | Open_content_picker -> prefs
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

let no_source = "No diagnostic source; launch with --synthetic-checker"

(* Why a view command naming a view that is not installed does nothing. *)
let view_unavailable t id =
  Option.value (View_registry.unavailable_notice t.views id)
    ~default:(sprintf "View %s unavailable" (View_id.to_string id))
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
  | Present_buffers presentation -> Some
      (match presentation with
       | Top -> "Open buffers in top strip"
       | Status_rows -> if t.zen then "Buffer rows saved for workspace; zen"
         else if buffers_in_status t ~width ~height then "Open buffers in status rows"
         else "Status rows requested (top strip fallback)")
  | Focus_view _ | Focus_other_pane ->
    let focused = Host.spec t.host (focused_view t ~width ~height) in
    Some (Option.value (Host.notice t.host) ~default:(focused.title ^ " focused"))
  | Place_view _ -> Host.notice t.host
  | Swap_split | Adjust_split _ ->
    let split = t.split in
    let side =
      match split.view_side with
      | Left -> "left"
      | Right -> "right"
    in
    let columns =
      Option.bind (View_registry.split t.views) ~f:(fun id ->
        Workspace.minor (workspace t ~width ~height) id)
      |> Option.value_map ~default:"not shown" ~f:(fun pane ->
        sprintf "%d columns" pane.rect.width)
    in
    Some (sprintf "Split view %s %d%% (%s)" side split.percent columns)
  | Toggle_view id ->
    Some
      (if not (View_registry.installed t.views id)
       then view_unavailable t id
       else (
         let title = (Host.spec t.host id).title in
         if not (view_visible t id)
         then title ^ " hidden"
         else if Option.is_none (view_layout t ~width ~height id)
         then title ^ " requested (compact/zen)"
         else title ^ " shown"))
  | Run_view_command _ -> Host.notice t.host
  | Toggle_entry_mark | Mark_selection | Unmark_selection | Clear_directory_marks | Open_marked_files
  | Toggle_directory | Open_directory_entry | Directory_parent | Refresh_directory -> None
  | Directory_major -> Option.map (Session.directory_presentation t.session) ~f:(fun _ -> "Directory in major tile")
  | Directory_side -> Option.map (Session.directory_presentation t.session) ~f:(fun _ ->
      if Option.is_some (side_layout t ~width ~height) then "Directory in left side tile" else "Directory side requested (compact/zen/no file)")
  | Hide_directory -> None
  | Focus_directory -> Option.map (Session.directory_presentation t.session) ~f:(fun _ ->
      if Option.is_some (Session.input_directory t.session) then "Directory focused" else "Editor focused")
  | Adjust_directory_size _ -> Some (sprintf "Directory width %d (requested)" t.directory_size)
  | Restart_source ->
    Some (if t.source_attached then "Diagnostic source restart requested" else no_source)
  | Kill_source ->
    Some (if t.source_attached then "Diagnostic source kill requested" else no_source)
  | Inspect_problems | Scroll _ | Next_tab | Previous_tab | Close_tab | Force_close_tab | Recreate_missing_file -> None
     | Open_palette | Open_line_picker | Open_file_picker | Open_content_picker -> Host.notice t.host
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

(* Ask [source]'s question on a float over it, focused; the view is not left. A
   float that cannot fit, or a view no longer shown, withdraws the question with a
   notice instead. *)
let open_ask t ~width ~height ~source (question : View_registry.Ask.Question.t) =
  let t = close_ask t in
  let refuse title (minimum : Floating.Size.t) =
    pane_notice { t with views = View_registry.withdraw t.views source } ~source
      (sprintf "%s cannot fit; needs at least %d columns and %d rows; nothing ran" title
         minimum.width minimum.height)
  in
  if not (available t ~width ~height source)
  then
    pane_notice { t with views = View_registry.withdraw t.views source } ~source
      (sprintf "%s is not shown; nothing ran" (Host.spec t.host source).title)
  else (
    match question with
    | Confirm { title; message } ->
      let confirm = Confirm_tile.create ~origin:source ~title ~message in
      if Option.is_none (confirm_placement confirm ~width ~height)
      then refuse title Confirm_tile.minimum
      else { t with confirm = Some confirm; host = Host.focus t.host Confirm_tile.id }
    | Prompt { title; initial; validate } ->
      if Option.is_none (prompt_placement ~width ~height)
      then refuse title Prompt_tile.minimum
      else
        { t with
          prompt = Some (Prompt_tile.create ~origin:source ~title ~initial ~validate)
        ; host = Host.focus t.host Prompt_tile.id
        })
;;

(* What an adapter's action asks for, in order: the controller, a text effect, a
   notice, then returning to the document, showing its file tab over a view tab, then
   its question. *)
let apply_outcome t ~width ~height ~source
      { View_registry.Outcome.controller; effect; notice; return; ask }
  =
  let t = text_effect { t with controller } ~source effect in
  let t =
    match notice with
    | None -> t
    | Some (`Post text) -> pane_notice t ~source text
    | Some (`Show text) -> { t with host = Host.with_notice t.host text }
  in
  let t = if return then return_to_document (file_tab t) else t in
  Option.value_map ask ~default:t ~f:(open_ask t ~width ~height ~source)
;;

(* Close the question float, refocus the view that asked (or return to the document
   when it is gone), and deliver [answer] to it. *)
let answer_ask t ~width ~height answer =
  match ask_origin t with
  | None -> return_to_document t
  | Some origin ->
    let t = close_ask t in
    let t =
      if available t ~width ~height origin
      then { t with host = Host.focus t.host origin }
      else return_to_document t
    in
    (match
       View_registry.answer t.views origin answer ~controller:t.controller
         ~rows:(minor_rows t ~width ~height origin) ~width:(minor_width t ~width ~height origin)
     with
     | views, None -> { t with views }
     | views, Some outcome -> apply_outcome { t with views } ~width ~height ~source:origin outcome)
;;

(* A local command by name, as its keys would run it: only in the focused view. *)
let run_view_command t ~width ~height id command =
  let title =
    if View_registry.installed t.views id then (Host.spec t.host id).title
    else View_id.to_string id
  in
  if not (View_id.equal (focused_view t ~width ~height) id)
  then { t with host = Host.with_notice t.host (sprintf "%s is not focused; nothing ran" title) }
  else (
    match
      View_registry.run t.views id command ~controller:t.controller
        ~rows:(minor_rows t ~width ~height id) ~width:(minor_width t ~width ~height id)
    with
    | Error error -> pane_notice t ~source:id (Error.to_string_hum error)
    | Ok (views, outcome) -> apply_outcome { t with views } ~width ~height ~source:id outcome)
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

(* The palette entries for [origin]'s local commands, first in the palette, with
   their keys as shortcuts. Ids are [local.<view>.<command>]; a malformed name is left
   out rather than refusing the palette. *)
let local_entries t origin =
  match origin with
  | None -> []
  | Some view ->
    let title = (Host.spec t.host view).title in
    View_registry.commands t.views view
    |> List.filter ~f:(fun (command : Ches_tile.Local_command.t) ->
      Ches_tile.Local_command.valid_name command.name
      && Ches_tile.Local_command.valid_name (View_id.to_string view)
      && not (String.is_empty (String.strip command.description)))
    |> List.stable_dedup ~compare:(fun (a : Ches_tile.Local_command.t) b ->
      String.compare a.name b.name)
    |> List.map ~f:(fun (command : Ches_tile.Local_command.t) ->
      ( Ches_palette.Catalog.Entry.create
          ~id:(sprintf "local.%s.%s" (View_id.to_string view) command.name)
          ~title:(sprintf "%s: %s" title command.description)
          ~keywords:[ "local"; String.lowercase title; command.name ]
          (View (Run_view_command { view; command = command.name }))
      , command.keys ))
;;

(* Open the palette for the document, focused, including in zen. It needs a framed
   query and result row. Over a registered view (or its help) it lists that view's
   local commands first and keeps the view as it is, to run one there; any other
   command, or closing, returns to the document as before. From another view it
   leaves that view. Refusal does not disturb the current focus. *)
let open_palette t ~width ~height =
  let notice text = { t with host = Host.with_notice t.host text } in
  let editor = Controller.editor t.controller in
  if not (has_document t)
  then notice "No file open; Space q quits the session"
  else if not (Mode.equal (Editor.mode editor) Normal)
  then notice "Leave Insert/Visual mode before opening the command palette"
  else if Option.is_none (palette_placement ~width ~height)
  then notice "Command palette cannot fit; needs at least 14 columns and 4 rows"
  else (
    let current = focused_view t ~width ~height in
    let origin =
      if View_registry.installed t.views current
      then Some current
      else Option.map t.help ~f:Help_tile.origin
    in
    let local = local_entries t origin in
    let catalog =
      if List.is_empty local
      then Ches_palette.Catalog.default
      else (
        match
          Ches_palette.Catalog.create
            (List.map local ~f:fst @ Ches_palette.Catalog.entries Ches_palette.Catalog.default)
        with
        | Ok catalog -> catalog
        | Error _ -> Ches_palette.Catalog.default)
    in
    let palette =
      Palette_tile.create
        catalog
        { mode = Editor.mode editor }
        ~token:document_id
        ~bindings:(Bindings.to_list (Keymap.bindings (Controller.keymap t.controller)))
        ~shortcuts:
          (List.map local ~f:(fun (entry, keys) -> Ches_palette.Catalog.Entry.id entry, keys))
    in
    let t =
      { (if View_registry.installed t.views current then t else leave t current) with
        controller = Controller.cancel_pending t.controller
      ; palette = Some palette
      ; palette_origin = origin
      }
    in
    { t with
      host = Host.focus t.host Palette_tile.id
    ; palette =
        Some (Palette_tile.fit palette ~rows:(minor_rows t ~width ~height Palette_tile.id))
    })
;;

(* Provider assembly boundary. The frontend owns discovery; release cancels it
   on every close path, before queued session acceptance. *)
let can_open_file_picker t ~width ~height =
  not t.exited
  && Mode.equal (Editor.mode (Controller.editor t.controller)) Normal
   && Option.is_some (picker_placement ~width ~height)
  && not (Host.pasting t.host)
;;

let open_file_picker t ~width ~height ~discovery ~release =
  if not (can_open_file_picker t ~width ~height)
  then (
    release ();
    { t with host = Host.with_notice t.host
        "Files unavailable: finish paste, leave Insert/Visual, and allow at least 14 columns and 5 rows" })
  else (
    let previous = match t.file_picker with
      | Some _ -> t.file_picker_return
      | None -> focused_view t ~width ~height in
    let t = leave t (focused_view t ~width ~height) in
    let picker = File_picker_tile.create ~token:document_id ~discovery in
    let t = { t with file_picker = Some picker; file_picker_release = release
      ; file_picker_return = previous; controller = Controller.cancel_pending t.controller
      ; host = Host.focus t.host File_picker_tile.id } in
    File_picker_tile.fit picker ~rows:(minor_rows t ~width ~height File_picker_tile.id);
    t)
;;

let open_line_picker t ~width ~height =
  if not (can_open_file_picker t ~width ~height)
  then { t with host = Host.with_notice t.host
    "Document lines unavailable: finish paste, leave Insert/Visual, and allow at least 14 columns and 5 rows" }
  else (
    let previous = match t.line_picker with
      | Some _ -> t.line_picker_return
      | None -> focused_view t ~width ~height in
    let t = leave t (focused_view t ~width ~height) in
    let picker = Line_picker_tile.create t.controller in
    let t = { t with line_picker = Some picker; line_generation = t.line_generation + 1
      ; line_picker_return = previous; controller = Controller.cancel_pending t.controller
      ; host = Host.focus t.host Line_picker_tile.id } in
    Line_picker_tile.fit picker ~rows:(minor_rows t ~width ~height Line_picker_tile.id);
    t)
;;

let open_content_picker t ~width ~height ~snapshot ~release =
  if not (can_open_file_picker t ~width ~height) then (release (); t)
  else (
    let previous = match t.content_picker with
      | Some _ -> t.content_picker_return
      | None -> focused_view t ~width ~height in
    let t = leave t (focused_view t ~width ~height) in
    let picker = Content_picker_tile.create ~token:document_id ~snapshot in
    let t = { t with content_picker = Some picker; content_picker_release = release
      ; content_picker_return = previous; controller = Controller.cancel_pending t.controller
      ; host = Host.focus t.host Content_picker_tile.id } in
    Content_picker_tile.fit picker ~rows:(minor_rows t ~width ~height Content_picker_tile.id);
    t)
;;

(* Close view [id] from any placement, through the registry. Its tab, if active,
   gives way to the active file tab; focus in it returns. *)
let close_view t ~width ~height id =
  let focused = View_id.equal (focused_view t ~width ~height) id in
  let t =
    { t with
      views = View_registry.close t.views id
    ; host = Host.invalidate_paste t.host id
    ; rows = None
    }
  in
  let t = if Option.is_some (active_tab_view t) then t else file_tab t in
  if focused then return_to_document t else t
;;

let split_needs = Workspace.min_document_width + Workspace.gap + Workspace.min_split_width

(* Move installed view [id] out of its placement into [placement]. A tab is added
   after the active entry and activated; tab and split views are focused when they
   can be shown. The notice says where the view went. *)
let place_view t ~width ~height id (placement : View_registry.Placement.t) =
  let title = view_title t id in
  let previous = View_registry.placement t.views id in
  let was_active_tab = Option.exists (active_tab_view t) ~f:(View_id.equal id) in
  let focus t =
    let current = focused_view t ~width ~height in
    if not (available t ~width ~height id)
    then t
    else (
      let t = if View_id.equal current id then t else leave t current in
      { t with host = Host.focus t.host id })
  in
  let notice text t = { t with host = Host.with_notice t.host text } in
  let t = { t with rows = None; controller = Controller.cancel_pending t.controller } in
  match placement with
  | Hidden -> notice (title ^ " closed") (close_view t ~width ~height id)
  | Tab when Option.equal View_registry.Placement.equal previous (Some Tab) ->
    notice (title ^ " in tab strip") (show_view_tab t ~width ~height id)
  | Tab ->
    let after = active_tab t in
    let views = View_registry.set_placement t.views id Tab in
    let tabs =
      Tab_strip.add t.tabs
        ~files:(List.map (Session.buffers t.session) ~f:fst)
        ~views:(View_registry.tabs views) id ~after
    in
    notice (title ^ " in tab strip") (focus { t with views; tabs })
  | Band | Split ->
    let t = { t with views = View_registry.set_placement t.views id placement } in
    let t = if was_active_tab then file_tab t else t in
    let t =
      match placement with
      | Split -> focus t
      | Hidden | Band | Tab -> t
    in
    let shown = Option.is_some (view_layout t ~width ~height id) in
    let where =
      match placement with
      | Split when shown -> " in split"
      | Split when t.zen -> " split requested (zen)"
      | Split -> sprintf " split hidden: needs %d columns" split_needs
      | Hidden | Band | Tab when shown -> " in bottom band"
      | Hidden | Band | Tab -> " band requested (compact/zen)"
    in
    notice (title ^ where) t
;;

(* The view a placement command names: [None] is the focused registered view. *)
let place_named t ~width ~height view placement =
  let focused = focused_view t ~width ~height in
  match view with
  | None when View_registry.installed t.views focused ->
    place_view t ~width ~height focused placement
  | None -> { t with host = Host.with_notice t.host "No view focused; focus a view to move it" }
  | Some id when View_registry.installed t.views id -> place_view t ~width ~height id placement
  | Some id -> { t with host = Host.with_notice t.host (view_unavailable t id) }
;;

(* In the major split, focus the split view or return to the active tab. *)
let focus_other_pane t ~width ~height =
  match View_registry.split t.views with
  | Some id when available t ~width ~height id ->
    let current = focused_view t ~width ~height in
    if View_id.equal current id
    then return_to_document t
    else (
      let t = leave t current in
      { t with host = Host.focus t.host id; controller = Controller.cancel_pending t.controller })
  | Some _ | None -> { t with host = Host.with_notice t.host "No split view shown" }
;;

let apply_view_command t ~width ~height (view : View_command.t) =
  match view with
  | Present_buffers buffer_presentation ->
    { t with buffer_presentation; rows = None
      ; animation = Animation.create ~enabled:(Animation.enabled t.animation) }
  | Directory_major ->
    adopt_session_state (file_tab t) (Session.set_directory_placement (session t) Major) ~width ~height
  | Directory_side ->
    adopt_session_state t (Session.set_directory_placement (session t) Side) ~width ~height
  | Hide_directory ->
    adopt_session_state ~keep_view_tab:true t (Session.hide_directory (session t)) ~width ~height
  | Recreate_missing_file -> adopt_session_state t (Session.recreate_current (session t)) ~width ~height
  | Focus_directory ->
    let s = session t in
    let s = if Option.is_none (Session.directory_buffer s) then Session.set_directory_placement s Side
      else Session.focus_directory s (Option.is_none (Session.input_directory s) || Option.is_none (Session.active_id s)) in
    adopt_session_state ~keep_view_tab:true t s ~width ~height
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
    (match active_tab_view t, Session.active_id (session t) with
     | Some id, _ -> close_view t ~width ~height id
     | None, None -> t
     | None, Some id -> fst (close_buffer_state t ~width ~height id ~force:(View_command.equal view Force_close_tab)))
  | Open_palette -> open_palette t ~width ~height
  | Open_line_picker -> open_line_picker t ~width ~height
  | Open_file_picker -> { t with file_picker_activation = true }
  | Open_content_picker -> { t with content_picker_activation = true }
  | Focus_view id ->
    if not (View_registry.installed t.views id)
    then { t with host = Host.with_notice t.host (view_unavailable t id) }
    else (
      match View_registry.placement t.views id with
      | Some Tab
        when Option.exists (active_tab_view t) ~f:(View_id.equal id)
             && View_id.equal (focused_view t ~width ~height) id ->
        (* The focused view tab gives way to the active file tab. *)
        return_to_document (file_tab t)
      | Some Tab ->
        toggle_focus t ~width ~height id ~show:(fun t ->
          { t with tabs = Tab_strip.activate t.tabs (Some id); rows = None })
      | Some (Hidden | Band | Split) | None ->
        toggle_focus t ~width ~height id ~show:(fun t ->
          if view_visible t id then t
          else { t with views = View_registry.set_placement t.views id Band }))
  | Toggle_view id ->
    if not (View_registry.installed t.views id)
    then t
    else if view_visible t id
    then close_view t ~width ~height id
    else { t with views = View_registry.set_placement t.views id Band }
  | Place_view { view; placement } -> place_named t ~width ~height view placement
  | Focus_other_pane -> focus_other_pane t ~width ~height
  | Swap_split -> { t with split = Workspace.Major_split.swap t.split; rows = None }
  | Adjust_split points ->
    { t with split = Workspace.Major_split.adjust t.split points; rows = None }
  | Run_view_command { view; command } -> run_view_command t ~width ~height view command
  | Restart_source when t.source_attached ->
    { t with source_commands = Restart :: t.source_commands }
  | Kill_source when t.source_attached ->
    { t with source_commands = Kill :: t.source_commands }
  | Restart_source | Kill_source -> t
  | Toggle_problems_filter ->
    { t with views = View_registry.map t.views Problems_tile.key ~f:Problems_tile.toggle_filter }
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

let split_shown t ~width ~height =
  Option.exists (View_registry.split t.views) ~f:(fun id ->
    Option.is_some (Workspace.minor (workspace t ~width ~height) id))
;;

(* After a resize, say when the split view stopped or started fitting. It stays in
   the split placement either way. [before] is whether it fit the last dimensions. *)
let split_notice t ~before ~width ~height =
  match View_registry.split t.views, before with
  | Some id, Some before when (not t.zen) && Bool.(before <> split_shown t ~width ~height) ->
    let text =
      if before
      then sprintf "%s split hidden: needs %d columns" (view_title t id) split_needs
      else view_title t id ^ " split restored"
    in
    { t with
      controller =
        Controller.update_feedback t.controller
          (Notify { source = "workspace"; scope = None; severity = Info; text; history = false })
    }
  | _ -> t
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

(* Open help for registered view [origin], over it: the view is not left. *)
let open_help t ~width ~height origin =
  let title = (Host.spec t.host origin).title in
  let help = Help_tile.create ~origin ~title (View_registry.commands t.views origin) in
  if Option.is_none (help_placement help ~width ~height)
  then { t with host = Host.with_notice t.host "Help cannot fit; needs at least 14 columns and 3 rows" }
  else { t with help = Some help; host = Host.focus t.host Help_tile.id }
;;

(* A key typed into captured view [id]: the host decides, then the view's adapter
   performs its own actions. This is the only place adapters meet the host. *)
let feed_capture t ~width ~height id key =
  match
    View_registry.key t.views id t.host key
      ~lookup:(Keymap.lookup (Controller.keymap t.controller))
      ~controller:t.controller
      ~rows:(minor_rows t ~width ~height id)
      ~width:(minor_width t ~width ~height id)
  with
  | None -> return_to_document t
  | Some (views, host, step) ->
    let t = { t with views; host } in
    (match step with
     | Handled -> t
     | Return -> return_to_document t
     | Notice text -> pane_notice t ~source:id text
     | Workspace view -> apply_view_command t ~width ~height view
     | Help -> open_help t ~width ~height id
     | Performed outcome -> apply_outcome t ~width ~height ~source:id outcome)
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
    | _ when View_id.equal id Content_picker_tile.id ->
      Option.iter t.content_picker ~f:(fun picker ->
        Content_picker_tile.update picker ~rows:(minor_rows t ~width ~height id) (Paste text));
      t
    | _ when View_id.equal id Line_picker_tile.id ->
      Option.iter t.line_picker ~f:(fun picker ->
        Line_picker_tile.update picker ~rows:(minor_rows t ~width ~height id) (Paste text));
      t
    | _ when View_id.equal id File_picker_tile.id ->
      Option.iter t.file_picker ~f:(fun picker ->
        File_picker_tile.update picker ~rows:(minor_rows t ~width ~height id) (Paste text));
      t
    | _ when View_id.equal id Prompt_tile.id ->
      { t with prompt = Option.map t.prompt ~f:(fun prompt -> Prompt_tile.update prompt (Paste text)) }
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
  | Execute { action = View (Run_view_command { view; _ } as command); _ } ->
    (* A local command runs in the view the palette was opened over, refocused. *)
    let origin = t.palette_origin in
    let t = leave t Palette_tile.id in
    (match origin with
     | Some origin when View_id.equal origin view && available t ~width ~height view ->
       let t =
         { t with
           host = Host.focus t.host view
         ; controller = Controller.cancel_pending t.controller
         }
       in
       apply_view_command t ~width ~height command, Running
     | Some _ | None -> refuse "The palette's view is gone; nothing ran", Running)
  | Execute { action; _ } ->
    (* Moving "the focused view" moves the view the palette was opened over. *)
    let action : Keymap.Action.t =
      match action, t.palette_origin with
      | View (Place_view { view = None; placement }), Some origin ->
        View (Place_view { view = Some origin; placement })
      | _ -> action
    in
    let t = return_to_document t in
     let session, views, status = Session.dispatch (session t) [ action ] in
     let t = adopt_session_state t session ~width ~height in
    let controller = Option.value (Session.active_controller session) ~default:(Controller.with_feedback t.controller (Session.feedback session)) in
    finish_step { t with session } ~width ~height ~controller ~views ~keymap_notice:None, status
;;

(* A key typed into the open palette. Every character is query text (it accepts text),
   so only Escape and Ctrl-c are the host's; Tab/Shift-Tab reach result navigation. *)
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
  | Some id when View_id.equal id Content_picker_tile.id ->
    let host, decision = Host.key t.host key
      ~lookup:(Keymap.lookup (Controller.keymap t.controller))
      ~content:Content_picker_tile.interpret ~escape:None ~hint:Palette_tile.hint in
    let t = { t with host } in
    let t = match decision, t.content_picker with
      | Return, _ -> close_content_picker t ~width ~height
      | Content Accept, Some picker ->
        let updated = ref t in
        Content_picker_tile.accept picker
          ~release:(fun () ->
            t.content_picker_release ();
            updated := close_content_picker t ~width ~height)
          ~consume:(fun request ->
            updated := { !updated with content_requests = request :: !updated.content_requests });
        !updated
      | Content (Event event), Some picker ->
        Content_picker_tile.update picker ~rows:(minor_rows t ~width ~height id) event; t
      | Notice text, _ -> { t with host = Host.with_notice t.host text }
      | Workspace view, _ -> apply_view_command t ~width ~height view
      | Handled, _ | Content _, None -> t in
    t, Controller.Status.Running
  | Some id when View_id.equal id Line_picker_tile.id ->
    let host, decision = Host.key t.host key
      ~lookup:(Keymap.lookup (Controller.keymap t.controller))
      ~content:Line_picker_tile.interpret ~escape:None ~hint:Palette_tile.hint in
    let t = { t with host } in
    let t = match decision, t.line_picker with
      | Return, _ -> close_line_picker t ~width ~height
      | Content Accept, Some picker ->
        let updated = ref t in
        let result = Line_picker_tile.accept picker
          ~current:(fun () -> !updated.controller)
          ~release:(fun () -> updated := close_line_picker !updated ~width ~height) in
        (match result with
         | Ok None -> !updated
         | Ok (Some controller) -> { !updated with controller }
         | Error error -> pane_notice (close_line_picker !updated ~width ~height)
             ~source:id (Error.to_string_hum error))
      | Content (Event event), Some picker ->
        Line_picker_tile.update picker ~rows:(minor_rows t ~width ~height id) event; t
      | Notice text, _ -> { t with host = Host.with_notice t.host text }
      | Workspace view, _ -> apply_view_command t ~width ~height view
      | Handled, _ | Content _, None -> t
    in
    t, Controller.Status.Running
  | Some id when View_id.equal id directory_id ->
    (* A directory is a modal document, not a details/palette capture. In
       particular Space, Visual Enter, search and mark bindings use its keymap. *)
    if Key.equal key Tab && not (Mode.equal (Editor.mode (Controller.editor t.controller)) Insert) then
      apply_view_command t ~width ~height Focus_directory, Controller.Status.Running
    else feed t ~width ~height (Key key)
  | Some id when View_id.equal id Help_tile.id ->
    let host, decision = Host.key t.host key
      ~lookup:(Keymap.lookup (Controller.keymap t.controller))
      ~content:Help_tile.interpret ~escape:None ~hint:Help_tile.hint in
    let t = { t with host } in
    let t = match decision, t.help with
      | (Return | Content Close), _ -> close_help t ~width ~height
      | Content (Scroll motion), Some help ->
        { t with help = Some (Help_tile.scroll help ~rows:(minor_rows t ~width ~height id) motion) }
      | Notice text, _ -> { t with host = Host.with_notice t.host text }
      | Workspace view, _ -> apply_view_command t ~width ~height view
      | Handled, _ | Content _, None -> t
    in
    t, Controller.Status.Running
  | Some id when View_id.equal id Confirm_tile.id || View_id.equal id Prompt_tile.id ->
    (* Ctrl-c declines here, beside Escape and Tab, which return. *)
    let decline = Key.equal key (Ctrl 'c') in
    let t =
      if View_id.equal id Confirm_tile.id
      then (
        let host, decision =
          if decline then t.host, Host.Decision.Return
          else Host.key t.host key
              ~lookup:(Keymap.lookup (Controller.keymap t.controller))
              ~content:Confirm_tile.interpret ~escape:None ~hint:Confirm_tile.hint
        in
        let t = { t with host } in
        match decision with
        | Content Yes -> answer_ask t ~width ~height Yes
        | Return | Content No -> answer_ask t ~width ~height No
        | Notice text -> { t with host = Host.with_notice t.host text }
        | Workspace view -> apply_view_command t ~width ~height view
        | Handled -> t)
      else (
        let host, decision =
          if decline then t.host, Host.Decision.Return
          else Host.key t.host key
              ~lookup:(Keymap.lookup (Controller.keymap t.controller))
              ~content:Prompt_tile.interpret ~escape:None ~hint:Prompt_tile.hint
        in
        let t = { t with host } in
        match decision, t.prompt with
        | Return, _ -> answer_ask t ~width ~height No
        | Content Accept, Some prompt ->
          (match Prompt_tile.accept prompt with
           | Ok text -> answer_ask t ~width ~height (Text text)
           | Error prompt -> { t with prompt = Some prompt })
        | Content (Edit event), Some prompt ->
          { t with prompt = Some (Prompt_tile.update prompt event) }
        | Notice text, _ -> { t with host = Host.with_notice t.host text }
        | Workspace view, _ -> apply_view_command t ~width ~height view
        | Handled, _ | Content _, None -> t)
    in
    t, Controller.Status.Running
  | Some id when View_id.equal id Palette_tile.id ->
    (match t.palette with
     | Some palette -> feed_palette t ~width ~height palette key
     | None -> return_to_document t, Controller.Status.Running)
  | Some id when View_id.equal id File_picker_tile.id ->
    let host, decision = Host.key t.host key
      ~lookup:(Keymap.lookup (Controller.keymap t.controller))
      ~content:File_picker_tile.interpret ~escape:None ~hint:Palette_tile.hint in
    let t = { t with host } in
    let t = match decision, t.file_picker with
      | Return, _ -> close_file_picker t ~width ~height
      | Content Accept, Some picker ->
        let updated = ref t in
        File_picker_tile.accept picker
          ~release:(fun () ->
            t.file_picker_release ();
            updated := close_file_picker t ~width ~height)
          ~consume:(fun request ->
            updated := { !updated with file_requests = request :: !updated.file_requests });
        !updated
      | Content (Event event), Some picker ->
        File_picker_tile.update picker ~rows:(minor_rows t ~width ~height id) event; t
      | Notice text, _ -> { t with host = Host.with_notice t.host text }
      | Workspace view, _ -> apply_view_command t ~width ~height view
      | Handled, _ | Content _, None -> t
    in
    t, Controller.Status.Running
  | Some id -> feed_capture t ~width ~height id key, Controller.Status.Running
  | None -> feed t ~width ~height (Key key)
;;

let refit t ~width ~height =
  let t = synchronize t ~width ~height in
  { t with
    scroll = fitted_scroll t ~width ~height
  ; rows = Some (geometry t ~width ~height).text.height
  ; fitted_dimensions = Some (width, height)
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
       { t with views = View_registry.map t.views Problems_tile.key ~f:(fun problems ->
           Problems_tile.applied problems ~source ~resource ~text) }
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
  match input with
  | Content_picker_accept request ->
    let position = ref None in
    let validate controller =
      let editor = Controller.editor controller in
      let text = Editor.text editor in
      let index = request.line - 1 in
      let invalid () = Or_error.error_string "Content result changed or invalid; reopen search (on disk)" in
      if request.line <= 0 || index >= Ches_core.Text_buffer.line_count text
      then invalid () else
      let line = Ches_core.Text_buffer.line_text text index in
      (* rg includes the final LF in raw lines; the editor's line API excludes it.
         Unsupported CR/CRLF is rejected by file IO, never normalized. *)
      let raw = line ^ (if Ches_core.Text_buffer.line_end text index < Ches_core.Text_buffer.length text
        then "\n" else "") in
      if not (String.equal raw request.expected_text)
         || String.is_empty request.literal || request.byte_column < 0
         || request.end_byte <= request.byte_column || request.end_byte > String.length line
         || request.end_byte - request.byte_column <> String.length request.literal
         || not (String.equal (String.sub line ~pos:request.byte_column
              ~len:(request.end_byte - request.byte_column)) request.literal)
      then invalid () else
      let offset = Ches_core.Text_buffer.line_start text index in
      Or_error.bind (Editor.display_position_of_offset editor (offset + request.end_byte)) ~f:(fun _ ->
        Or_error.map (Editor.display_position_of_offset editor (offset + request.byte_column))
          ~f:(fun p -> position := Some p)) in
    let t = match Session.open_or_activate ~must_exist:true ~validate (session t) request.path with
      | Ok (session, _) ->
        let line, column = Option.value_exn !position in
        let controller = Controller.jump (Option.value_exn (Session.active_controller session))
          ~line ~column |> Or_error.ok_exn in
        adopt_session_state (return_to_document (file_tab t)) (Session.replace_active session controller) ~width ~height
      | Error error ->
        let text = Ches_file_picker.Model.Candidate.display_text (Error.to_string_hum error) in
        { t with host = Host.with_notice t.host text;
          controller = Controller.update_feedback t.controller
            (Notify { source = "content picker"; scope = path t; severity = Error; text; history = true }) } in
    release_held t ~width ~height, Running
  | File_picker_accept request ->
    let t = match Session.open_or_activate ~must_exist:true (session t) request.path with
      | Ok (session, _) -> adopt_session_state (return_to_document (file_tab t)) session ~width ~height
      | Error error ->
        let text = Ches_file_picker.Model.Candidate.display_text (Error.to_string_hum error) in
        { t with host = Host.with_notice t.host text;
          controller = Controller.update_feedback t.controller
            (Notify { source = "file picker"; scope = path t; severity = Error;
              text; history = true }) } in
    release_held t ~width ~height, Running
  | Content_picker_snapshot snapshot ->
    Option.iter t.content_picker ~f:(fun picker ->
      if Content_picker_tile.install picker snapshot then
        Content_picker_tile.fit picker ~rows:(minor_rows t ~width ~height Content_picker_tile.id));
    t, Running
  | Line_picker_work generation ->
    Option.iter t.line_picker ~f:(fun picker ->
      if generation = t.line_generation && Line_picker_tile.validate picker t.controller then (
        Line_picker_tile.work picker ~budget:128;
        if not (Ches_line_picker.Lines.busy (Line_picker_tile.session picker))
        then Line_picker_tile.fit picker ~rows:(minor_rows t ~width ~height Line_picker_tile.id)));
    t, Running
  | File_picker_snapshot snapshot ->
    Option.iter t.file_picker ~f:(fun picker -> ignore (File_picker_tile.install picker snapshot : bool));
    t, Running
  | File_picker_update update ->
    Option.iter t.file_picker ~f:(fun picker -> ignore (File_picker_tile.install_update picker update : bool));
    t, Running
  | File_preview snapshot ->
    Option.iter t.file_picker ~f:(fun picker ->
      ignore (File_picker_tile.install_preview picker snapshot : bool));
    t, Running
  | File_picker_work request ->
    Option.iter t.file_picker ~f:(fun picker ->
       let current = Ches_file_picker.Model.discovery_request
        (Ches_file_picker.Interaction.model (File_picker_tile.session picker)) in
      if Ches_file_picker.Model.Discovery.equal_request current request then (
        File_picker_tile.work picker ~budget:128;
        if not (Ches_file_picker.Interaction.busy (File_picker_tile.session picker))
        then File_picker_tile.fit picker ~rows:(minor_rows t ~width ~height File_picker_tile.id)));
    t, Running
  | _ -> apply_regular t ~width ~height input

and apply_regular t ~width ~height (input : Input.t) =
  (* Start from what is on screen: the stored scroll may predate a resize. *)
  let t = match input with
    | Animation_tick _ when Option.equal [%equal: int * int]
        t.fitted_dimensions (Some (width, height)) -> t
    | Resize ->
      Option.iter t.file_picker ~f:File_picker_tile.clear_preview;
      let before =
        Option.map t.fitted_dimensions ~f:(fun (width, height) -> split_shown t ~width ~height)
      in
      let t = synchronize t ~width ~height in
      split_notice { t with fitted_dimensions = Some (width, height) } ~before ~width ~height
    | _ -> refit t ~width ~height in
  match input with
  | Resize -> t, Running
  | Source event -> receive_all t ~width ~height [ event ], Running
     | File_preview _ | File_picker_snapshot _ | File_picker_update _ | File_picker_work _ | File_picker_accept _ | Content_picker_accept _ | Line_picker_work _ | Content_picker_snapshot _ -> assert false
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
    and before_placements = View_registry.placements t.views
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
       | Animation_tick _ | Resize | Source _ | File_preview _ | File_picker_snapshot _ | File_picker_update _ | File_picker_work _ | File_picker_accept _ | Content_picker_accept _ | Line_picker_work _ | Content_picker_snapshot _ -> assert false
    in
    let t = release_held t ~width ~height in
    let t = refit t ~width ~height in
    let after = cursor_position t ~width ~height in
    let was_active = Animation.active t.animation in
    let animation =
      if (not (Workspace.Prefs.equal before_workspace t.workspace_prefs))
          || not (Option.equal Buffer_id.equal before_buffer (Session.context_id t.session))
         || not
              ([%equal: (View_id.t * View_registry.Placement.t) list]
                 before_placements (View_registry.placements t.views))
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
let apply_all ?(after_step = Fn.id) t ~width ~height inputs =
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
       | t, Running -> Continue (after_step t)
      | t, Exit -> Stop (t, Controller.Status.Exit))
    ~finish:(fun t -> t, Running)
;;

let adopt_session t session ~width ~height =
  release_held (adopt_session_state t session ~width ~height) ~width ~height
;;

let take_file_picker_activation t =
  { t with file_picker_activation = false }, t.file_picker_activation
;;

let take_content_picker_activation t =
  { t with content_picker_activation = false }, t.content_picker_activation
;;

let with_notice ?(source = "file picker") t text =
  let text = Ches_file_picker.Model.Candidate.display_text text in
  { t with host = Host.with_notice t.host text;
    controller = Controller.update_feedback t.controller
      (Notify { source; scope = path t; severity = Error;
        text; history = true }) }
;;

let open_file t ~width ~height path =
  Or_error.map (Session.open_or_activate (session t) path) ~f:(fun (session, id) ->
    adopt_session (show_file_tab t) session ~width ~height, id)
;;
let activate_buffer t ~width ~height id =
  Or_error.map (Session.activate (session t) id) ~f:(fun session ->
    adopt_session (show_file_tab t) session ~width ~height)
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
