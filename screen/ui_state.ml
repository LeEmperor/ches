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
  [@@deriving sexp_of]
end

type t =
  { controller : Controller.t
  ; prefs : Geometry.Prefs.t
  ; scroll : Scroll.t
  ; paste : string list option (** Text collected so far, most recent first. *)
  ; message : Message.t option
  ; exited : bool
  }

let create ?(prefs = Geometry.Prefs.default) controller =
  { controller
  ; prefs
  ; scroll = Scroll.zero
  ; paste = None
  ; message = None
  ; exited = false
  }
;;

let controller t = t.controller
let prefs t = t.prefs
let scroll t = t.scroll
let message t = t.message
let pasting t = Option.is_some t.paste
let exited t = t.exited

let geometry t ~width ~height =
  Geometry.compute
    t.prefs
    ~width
    ~height
    ~line_count:
      (Text_buffer.line_count (Editor.text (Controller.editor t.controller)))
;;

let fitted_scroll t ~width ~height =
  let editor = Controller.editor t.controller in
  let text = Editor.text editor in
  let line = Editor.cursor_line editor in
  let span =
    Cell_map.cursor_span
      (Cell_map.glyphs (Text_buffer.line_text text line))
      ~pos:(Editor.cursor editor - Text_buffer.line_start text line)
      ~insertion:
        (match Editor.mode editor with
         | Insert -> true
         | Normal -> false)
  in
  let { Geometry.text = viewport; _ } = geometry t ~width ~height in
  Scroll.fit
    t.scroll
    ~line
    ~span
    ~rows:viewport.height
    ~cols:viewport.width
    ~line_count:(Text_buffer.line_count text)
;;

let min_width = 20
let max_width = 500
let max_offset = 500

let apply_view (prefs : Geometry.Prefs.t) (view : View_command.t) : Geometry.Prefs.t =
  match view with
  | Toggle_centered -> { prefs with centered = not prefs.centered }
  | Reset -> Geometry.Prefs.default
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
let view_feedback t ~width ~height (view : View_command.t) =
  let geometry = geometry t ~width ~height in
  let with_fit requested effective ~to_string =
    if requested = effective
    then to_string requested
    else sprintf "%s (%s fit)" (to_string requested) (to_string effective)
  in
  let signed n = if n = 0 then "0" else sprintf "%+d" n in
  match view with
  | Toggle_centered -> if t.prefs.centered then "Centered" else "Full width"
  | Reset -> "Layout reset"
  | Shift _ -> "Offset " ^ with_fit t.prefs.offset geometry.offset ~to_string:signed
  | Adjust_width _ ->
    "Width " ^ with_fit t.prefs.width geometry.text.width ~to_string:Int.to_string
;;

let feed t ~width ~height (input : Keymap.Input.t) =
  let controller, views, status = Controller.handle_input t.controller input in
  let t =
    { t with controller; prefs = List.fold views ~init:t.prefs ~f:apply_view }
  in
  let message =
    match Keymap.notice (Controller.keymap controller), List.last views with
    | Some text, _ -> Some { Message.kind = Warning; text }
    | None, Some view ->
      Some { Message.kind = Info; text = view_feedback t ~width ~height view }
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

let rec apply t ~width ~height (input : Input.t) =
  if t.exited then t, Controller.Status.Exit else apply_running t ~width ~height input

and apply_running t ~width ~height (input : Input.t) =
  (* Start from what is on screen: the stored scroll may predate a resize. *)
  let t = { t with scroll = fitted_scroll t ~width ~height } in
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
  in
  ( { t with
      scroll = fitted_scroll t ~width ~height
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
