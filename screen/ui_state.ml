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
  [@@deriving sexp_of]
end

type t =
  { controller : Controller.t
  ; prefs : Geometry.Prefs.t
  ; scroll : Scroll.t
  ; rows : int option
  (** Text rows the scroll was last fitted for: when they change, the fit fills the
      viewport (see {!Scroll.fit}). *)
  ; paste : string list option (** Text collected so far, most recent first. *)
  ; message : Message.t option
  ; animation : Animation.t
  ; animation_time : Time_ns.t option
  ; exited : bool
  }

let create ?(prefs = Geometry.Prefs.default) ?(smear_enabled = false) controller =
  { controller
  ; prefs
  ; scroll = Scroll.zero
  ; rows = None
  ; paste = None
  ; message = None
  ; animation = Animation.create ~enabled:smear_enabled
  ; animation_time = None
  ; exited = false
  }
;;

let controller t = t.controller
let prefs t = t.prefs
let scroll t = t.scroll
let message t = t.message
let pasting t = Option.is_some t.paste

let take_clipboard t =
  let controller, text = Controller.take_clipboard t.controller in
  { t with controller }, text
;;
let exited t = t.exited
let animation t = t.animation

let geometry t ~width ~height =
  Geometry.compute
    t.prefs
    ~width
    ~height
    ~line_count:
      (Text_buffer.line_count (Editor.text (Controller.editor t.controller)))
;;

(* The cursor's line and cells. A block insert's cursor is at its first insertion
   point, which before anything is typed can be inside a TAB or past the line's end,
   where the cursor's offset cannot be. *)
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

let fitted_scroll t ~width ~height =
  let editor = Controller.editor t.controller in
  let text = Editor.text editor in
  let line, span = cursor_cells editor in
  let { Geometry.text = viewport; _ } = geometry t ~width ~height in
  Scroll.fit
    t.scroll
    ~fill:(not ([%equal: int option] t.rows (Some viewport.height)))
    ~line
    ~span
    ~rows:viewport.height
    ~cols:viewport.width
    ~line_count:(Text_buffer.line_count text)
;;

let cursor_position t ~width ~height =
  let cursor_line, (start, _) = cursor_cells (Controller.editor t.controller) in
  let scroll = fitted_scroll t ~width ~height in
  let { Geometry.text = viewport; _ } = geometry t ~width ~height in
  let x = start - scroll.left and y = cursor_line - scroll.top in
  if x >= 0 && x < viewport.width && y >= 0 && y < viewport.height
  then Some (viewport.x + x, viewport.y + y)
  else None
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
  | Scroll _ | Toggle_smear -> prefs
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

(* Feedback for [view], just applied: the requested value, then the effective one on
   this screen when it differs. *)
let view_feedback t ~width ~height (view : View_command.t) : string option =
  let geometry = geometry t ~width ~height in
  let with_fit requested effective ~to_string =
    if requested = effective
    then to_string requested
    else sprintf "%s (%s fit)" (to_string requested) (to_string effective)
  in
  let signed n = if n = 0 then "0" else sprintf "%+d" n in
  match view with
  | Scroll _ -> None
  | Toggle_smear -> Some (if Animation.enabled t.animation then "Smear cursor enabled" else "Smear cursor disabled")
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

(* [scroll] from the fitted scroll, with the cursor on screen. The new first line is
   kept within the document: [Ctrl-e] stops with the last line at the top. When the
   cursor line would leave the view, the cursor is moved by a counted [Up]/[Down],
   which keeps its preferred column. *)
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
  | Scroll { scroll; count } -> scroll_view t ~width ~height scroll ~count
  | Toggle_smear -> { t with animation = Animation.set_enabled t.animation (not (Animation.enabled t.animation)) }
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
  let message =
    match Keymap.notice (Controller.keymap controller), List.last views with
    | Some text, _ -> Some { Message.kind = Warning; text }
    | None, Some view ->
      (match view_feedback t ~width ~height view with
       | Some text -> Some { Message.kind = Info; text }
       | None -> t.message)
    | None, None ->
      if Controller.last_input_dispatched controller
      then
        Option.map
          (Editor.message (Controller.editor controller))
          ~f:(function
            | Info text -> { Message.kind = Info; text }
            | Error text -> { Message.kind = Error; text })
      else t.message
  in
  { t with message }, status
;;

let refit t ~width ~height =
  { t with
    scroll = fitted_scroll t ~width ~height
  ; rows = Some (geometry t ~width ~height).text.height
  }
;;

let rec apply t ~width ~height (input : Input.t) =
  if t.exited then t, Controller.Status.Exit else apply_running t ~width ~height input

and apply_running t ~width ~height (input : Input.t) =
  (* Start from what is on screen: the stored scroll may predate a resize. *)
  let t = refit t ~width ~height in
  match input with
  | Animation_tick now ->
    let dt =
      Option.value_map t.animation_time ~default:0.017 ~f:(fun previous ->
        Time_ns.diff now previous |> Time_ns.Span.to_sec)
    in
    { t with animation = Animation.tick t.animation ~dt; animation_time = Some now }, Running
  | Key _ | Paste_start | Paste_end ->
    let before = cursor_position t ~width ~height in
    let t, status =
      match input, t.paste with
      | Paste_start, None -> { t with paste = Some [] }, Controller.Status.Running
      | Paste_start, Some _ -> t, Running
      | Paste_end, None -> t, Running
      | Paste_end, Some chunks ->
        feed ~width ~height { t with paste = None } (Paste (String.concat (List.rev chunks)))
      | Key key, Some chunks ->
        (match Key.text key with
         | Some text -> { t with paste = Some (text :: chunks) }, Running
         | None -> t, Running)
      | Key key, None -> feed ~width ~height t (Key key)
      | Animation_tick _, _ -> assert false
    in
    let t = refit t ~width ~height in
    let after = cursor_position t ~width ~height in
    let was_active = Animation.active t.animation in
    let animation = Animation.retarget t.animation ~from:before ~to_:after in
    { t with
      animation
    ; animation_time =
        (if (not was_active) && Animation.active animation then None else t.animation_time)
    ; exited = Controller.Status.equal status Exit
    }, status
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
