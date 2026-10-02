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

let feed t (input : Keymap.Input.t) =
  let controller, status = Controller.handle_input t.controller input in
  let message =
    match Keymap.notice (Controller.keymap controller) with
    | Some text -> Some { Message.kind = Warning; text }
    | None ->
      if Controller.last_input_dispatched controller
      then
        Option.map
          (Editor.message (Controller.editor controller))
          ~f:(function
            | Info text -> { Message.kind = Info; text }
            | Error text -> { Message.kind = Error; text })
      else t.message
  in
  { t with controller; message }, status
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
      feed { t with paste = None } (Paste (String.concat (List.rev chunks)))
    | Key key, Some chunks ->
      (match Key.text key with
       | Some text -> { t with paste = Some (text :: chunks) }, Running
       | None -> t, Running)
    | Key key, None -> feed t (Key key)
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
