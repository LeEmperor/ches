open! Core
open Ches_input
open Ches_palette
module Selection = Ches_tile.Navigation.Selection

let id = Ches_tile.View_id.of_string "palette"
let spec = Ches_tile.Spec.text_input id ~title:"Commands"

type t =
  { palette : (Ches_tile.View_id.t Palette.t[@sexp.opaque])
  ; view : Catalog.Id.t Selection.t
  ; shortcuts : (Catalog.Id.t * string) list (** The first binding of each entry. *)
  }
[@@deriving sexp_of]

let create catalog context ~token ~bindings =
  let shortcuts =
    List.filter_map (Catalog.entries catalog) ~f:(fun entry ->
      match Shortcut.sequences bindings (Catalog.Entry.action entry) with
      | [] -> None
      | keys :: _ -> Some (Catalog.Entry.id entry, Shortcut.to_string_hum keys))
  in
  { palette = Palette.create catalog context ~token; view = Selection.empty; shortcuts }
;;

let palette t = t.palette
let view t = t.view

let ids t =
  List.map (Palette.results t.palette) ~f:(fun (result : Catalog.result) ->
    Catalog.Entry.id result.item)
;;

(* The palette's selection is authoritative; the shared selection only scrolls to it. *)
let fit t ~rows =
  { t with
    view =
      Selection.fit
        { t.view with selected = Palette.selected t.palette }
        (ids t)
        ~equal:Catalog.Id.equal
        ~rows:(Int.max 1 (rows - 1))
  }
;;

type action =
  | Event of Palette.Event.t
  | Accept
[@@deriving sexp_of]

let interpret (keys : Key.t list) : action Ches_tile.Content_key.t =
  match keys with
  | [ Char c ] -> Action (Event (Insert c))
  | [ Backspace ] -> Action (Event Backspace)
  | [ Ctrl ('w' | 'h') ] -> Action (Event Delete_word)
  | [ Ctrl 'n' ] -> Action (Event Next)
  | [ Ctrl 'p' ] -> Action (Event Previous)
  | [ Enter ] -> Action Accept
  | _ -> Unbound
;;

let hint = "Type to search; Ctrl-w deletes a word, Ctrl-n/p select, Enter runs"
let update t ~rows event = fit { t with palette = Palette.update t.palette event } ~rows
let prompt = Picker_text.prompt

(* The prompt and as much of the query's end as leaves a cell for the cursor. *)
let query_row t ~width =
  Picker_text.query_row (Palette.query t.palette) ~width
;;

let cursor t ~width =
  Picker_text.cursor (Palette.query t.palette) ~width
;;

(* [title] with the code points starting at [positions] in [Pending]. *)
let title_spans = Picker_text.matched_text

(* A result: the selection marker, the title, and the shortcut flush right when the
   title leaves room for it. *)
let result_row t (result : Catalog.result) ~selected ~width =
  let marker =
    Span.of_text (if selected then prompt else "  ") ~style:Pending ~special:Status_special
  in
  let title =
    title_spans
      (Catalog.Entry.title result.item)
      ~positions:(Catalog.title_positions result)
  in
  let shortcut =
    List.Assoc.find t.shortcuts (Catalog.Entry.id result.item) ~equal:Catalog.Id.equal
    |> Option.value_map ~default:[] ~f:(fun keys ->
      Span.of_text keys ~style:Stale ~special:Status_special)
  in
  let fixed = Span.total_width marker in
  let shortcut =
    if fixed + Span.total_width title + 1 + Span.total_width shortcut <= width
    then shortcut
    else []
  in
  let title =
    Span.keep_left
      title
      ~n:(Int.max 0 (width - fixed - Span.total_width shortcut))
      ~marker_style:Status_special
  in
  let gap = Int.max 0 (width - fixed - Span.total_width title - Span.total_width shortcut) in
  Span.keep_left
    (marker @ title @ [ Span.blank Status gap ] @ shortcut)
    ~n:(Int.max 0 width)
    ~marker_style:Status_special
  |> Span.merge
;;

let render ?notice t ~width ~rows : Tile_shell.Content.t =
  let t = fit t ~rows in
  let results = Palette.results t.palette in
  let count = List.length results in
  let body =
    if rows <= 0
    then []
    else (
      let list =
        if count = 0
        then [ Tile_text.row Stale "No matching commands" ~width ]
        else
          List.take (List.drop results t.view.top) (rows - 1)
          |> List.mapi ~f:(fun i result ->
            result_row t result ~selected:(t.view.top + i = t.view.index) ~width)
      in
      let query = query_row t ~width in
      (query @ [ Span.blank Status (Int.max 0 (width - Span.total_width query)) ])
      :: List.take list (rows - 1))
  in
  { title = "Commands"
  ; footer =
      Some
        (Tile_shell.Label.footer
           ~notice
           ~pending:None
           ~default:
             (sprintf
                "%d/%d | Enter run, Ctrl-n/p, Esc"
                (if count = 0 then 0 else t.view.index + 1)
                count))
  ; body
  }
;;
