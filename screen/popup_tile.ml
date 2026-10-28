open! Core
open Ches_input
module Popup = Ches_vcs.Popup

let id = Ches_tile.View_id.of_string "popup"
let spec = Ches_tile.Spec.read_only id ~title:"Popup"

type t =
  { origin : Ches_tile.View_id.t
  ; popup : unit Popup.t
  ; state : Popup.State.t
  }
[@@deriving sexp_of]

let create ~origin popup = { origin; popup; state = Popup.initial popup }
let origin t = t.origin
let title t = t.popup.title
let popup t = t.popup
let state t = t.state
let cells text = Cell_map.total_width (Cell_map.glyphs text)
let gap = 3

(* Frame and padding around the content. *)
let chrome = 4

(* Each group's entries as drawn: the switches after their marker, then the actions
   after a blank one, so both line up. *)
let switch_entries t =
  let enabled = Popup.enabled t.popup t.state in
  List.map t.popup.switches ~f:(fun (switch : Popup.Switch.t) ->
    let on = List.mem enabled switch ~equal:Popup.Switch.equal in
    ( (if on then Style.Pending else Status)
    , sprintf "%s-%c  %s (%s)" (if on then "* " else "  ") switch.key switch.description
        switch.flag ))
;;

let action_entries t =
  List.map t.popup.actions ~f:(fun (action : _ Popup.Action.t) ->
    Style.Status, sprintf "  %c  %s" action.key action.description)
;;

(* [entries] in as many columns as fit [width], filled column by column. *)
let grid entries ~width =
  match entries with
  | [] -> []
  | entries ->
    let count = List.length entries in
    let column = List.fold entries ~init:0 ~f:(fun w (_, text) -> Int.max w (cells text)) in
    let columns = Int.clamp_exn ((width + gap) / (column + gap)) ~min:1 ~max:count in
    let rows = (count + columns - 1) / columns in
    let entries = Array.of_list entries in
    List.init rows ~f:(fun row ->
      let cells_of index =
        Option.map (Option.some_if (index < count) index) ~f:(fun index -> entries.(index))
      in
      let spans =
        List.init columns ~f:(fun col -> cells_of ((col * rows) + row))
        |> List.filter_opt
        |> List.concat_mapi ~f:(fun i (style, text) ->
          let spans = Span.of_text text ~style ~special:Status_special in
          let pad = if i = 0 then [] else [ Span.blank Status gap ] in
          pad @ spans @ [ Span.blank Status (Int.max 0 (column - Span.total_width spans)) ])
        |> Span.keep_left ~n:(Int.max 0 width) ~marker_style:Status_special
      in
      spans @ [ Span.blank Status (Int.max 0 (width - Span.total_width spans)) ])
;;

let lines t ~width =
  let group heading entries =
    match grid entries ~width with
    | [] -> []
    | rows -> Tile_text.row Hint heading ~width :: rows
  in
  group "Switches" (switch_entries t) @ group "Actions" (action_entries t)
;;

let minimum : Floating.Size.t = { width = 20; height = 4 }

let preferred_size t ~screen : Floating.Size.t =
  let actions =
    List.sum (module Int) (action_entries t) ~f:(fun (_, text) -> cells text)
    + (gap * Int.max 0 (List.length t.popup.actions - 1))
  in
  let switches =
    List.fold (switch_entries t) ~init:0 ~f:(fun w (_, text) -> Int.max w (cells text))
  in
  let width =
    Int.clamp_exn
      (Int.max (cells (title t)) (Int.max actions switches) + chrome)
      ~min:32
      ~max:76
  in
  (* The width it will get ([Floating.place]'s margin), so the height has room for
     the rows that narrower columns take. *)
  let fitted =
    Int.max minimum.width
      (Int.min width (if screen >= minimum.width + 2 then screen - 2 else screen))
  in
  { width; height = List.length (lines t ~width:(fitted - chrome)) + 2 }
;;

type action =
  | Press of char
  | Escape
  | Help
  | Close
[@@deriving sexp_of, equal]

let interpret (keys : Key.t list) : action Ches_tile.Content_key.t =
  match keys with
  | [ Char c ] ->
    (match Uchar.to_char c with
     | Some '?' -> Action Help
     | Some 'q' -> Action Close
     | Some c when Char.to_int c > 0x20 && Char.to_int c < 0x7f -> Action (Press c)
     | Some _ | None -> Unbound)
  | _ -> Unbound
;;

let hint = "Press a listed key; - then a key toggles a switch; ? lists the keys, q closes"

let press t key =
  match Popup.press t.popup t.state key with
  | Updated state -> `Updated { t with state }
  | Run () -> `Choose (key, t.state.enabled)
  | Unbound { state; key } ->
    `Unbound
      ({ t with state }, sprintf "%s is unbound; ? lists keys" key)
;;

let escape t =
  match Popup.escape t.state with
  | `Close -> `Close
  | `Updated state -> `Updated { t with state }
;;

let help t = Popup.help t.popup

let render ?(hotkey_hints = false) ?notice ?pending t ~width ~rows : Tile_shell.Content.t =
  let pending =
    Option.first_some pending (Option.some_if t.state.dash "-")
  in
  { title = title t
  ; footer =
      Some
        (Tile_shell.Label.footer ~notice ~pending
           ~default:(if hotkey_hints then "- switch  ? help  q close" else ""))
  ; body = List.take (lines t ~width) (Int.max 0 rows)
  }
;;
