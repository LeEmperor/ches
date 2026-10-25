open! Core
open Ches_input
module Query = Ches_palette.Query

let id = Ches_tile.View_id.of_string "prompt"
let spec = Ches_tile.Spec.text_input id ~title:"Prompt"

type t =
  { origin : Ches_tile.View_id.t
  ; title : string
  ; text : string
  ; validate : (string -> string option[@sexp.opaque])
  ; checked : bool (** Validation is shown: the text was edited, or Enter refused. *)
  }
[@@deriving sexp_of]

let create ~origin ~title ~initial ~validate =
  { origin; title; text = Query.sanitize initial; validate; checked = false }
;;

let origin t = t.origin
let title t = t.title
let text t = t.text
let error t = if t.checked then t.validate t.text else None
let preferred_size : Floating.Size.t = { width = 60; height = 4 }
let minimum : Floating.Size.t = { width = 20; height = 4 }

module Event = struct
  type t =
    | Insert of Uchar.t
    | Paste of string
    | Backspace
    | Delete_word
  [@@deriving sexp_of]
end

type action =
  | Edit of Event.t
  | Accept
[@@deriving sexp_of]

let interpret (keys : Key.t list) : action Ches_tile.Content_key.t =
  match keys with
  | [ Char c ] -> Action (Edit (Insert c))
  | [ Backspace ] -> Action (Edit Backspace)
  | [ Ctrl ('w' | 'h') ] -> Action (Edit Delete_word)
  | [ Enter ] -> Action Accept
  | _ -> Unbound
;;

let hint = "Type text; Ctrl-w deletes a word, Enter accepts, Escape cancels"

let update t (event : Event.t) =
  let text =
    match event with
    | Insert u -> Query.append t.text (Uchar.Utf8.to_string u)
    | Paste text -> Query.append t.text text
    | Backspace -> Query.backspace t.text
    | Delete_word -> Query.delete_word t.text
  in
  { t with text; checked = true }
;;

let accept t =
  match t.validate t.text with
  | None -> Ok t.text
  | Some _ -> Error { t with checked = true }
;;

let cursor t ~width = Picker_text.cursor t.text ~width

let render ?(hotkey_hints = false) ?notice t ~width ~rows : Tile_shell.Content.t =
  let input = Picker_text.query_row t.text ~width in
  let input = input @ [ Span.blank Status (Int.max 0 (width - Span.total_width input)) ] in
  let error =
    Tile_text.row (Option.map (error t) ~f:(fun _ -> Style.Error) |> Option.value ~default:Status)
      (Option.value (error t) ~default:"") ~width
  in
  { title = t.title
  ; footer =
      Some
        (Tile_shell.Label.footer
           ~notice
           ~pending:None
           ~default:(if hotkey_hints then "Enter accept | Esc cancel" else ""))
  ; body = List.take [ input; error ] (Int.max 0 rows)
  }
;;
