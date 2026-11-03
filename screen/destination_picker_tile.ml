open! Core
module L = Ches_error.Language_query
module Selection = Ches_tile.Navigation.Selection
module Query = Ches_palette.Query
module Fuzzy = Ches_palette.Fuzzy

let id = Ches_tile.View_id.of_string "destination-picker"
let spec = Ches_tile.Spec.result_picker id ~title:"Choose destination"

type t =
  { items : L.target list
  ; query : string
  ; view : int Selection.t
  }
[@@deriving sexp_of]

let position (target : L.target) =
  sprintf "%d:%d" (target.selection.start.line + 1) (target.selection.start.character + 1)
;;

let results t =
  List.mapi t.items ~f:(fun index target ->
    let field text weight = { Fuzzy.Field.tag = (); text; weight } in
    index, [field target.L.path 100; field (position target) 90])
  |> Fuzzy.rank ~query:t.query
;;

let result_rows rows = Int.max 1 (rows - 1)
let ids t = List.map (results t) ~f:(fun r -> r.Fuzzy.Match.item)
let fit t ~rows =
  { t with view = Selection.fit t.view (ids t) ~equal:Int.equal ~rows:(result_rows rows) }
;;
let create items = fit { items; query = ""; view = Selection.empty } ~rows:1
let selected t = Option.bind t.view.selected ~f:(List.nth t.items)
let query t = t.query
let interpret = Palette_tile.interpret
let cursor t ~width = Picker_text.cursor t.query ~width

let update t ~rows (event : Ches_palette.Palette.Event.t) =
  let query = match event with
    | Insert c -> Query.append t.query (Uchar.Utf8.to_string c)
    | Paste text -> Query.append t.query text
    | Backspace -> Query.backspace t.query
    | Delete_word -> Query.delete_word t.query
    | Next | Previous -> t.query
  in
  let t = fit (if String.equal query t.query then t
               else { t with query; view = Selection.empty }) ~rows in
  match event with
  | Next | Previous ->
    { t with view = Selection.move t.view (ids t) ~equal:Int.equal
        ~rows:(result_rows rows) (match event with Next -> Down | _ -> Up) }
  | _ -> t
;;

let encoding = function L.Utf8 -> "UTF-8" | Utf16 -> "UTF-16" | Utf32 -> "UTF-32"

let render ?(hotkey_hints = false) ?notice t ~width ~rows : Tile_shell.Content.t =
  let t = fit t ~rows in
  let matches = results t in
  let body = if rows <= 0 then [] else
    Picker_text.query_row t.query ~width ::
    (if List.is_empty matches then [Tile_text.row Stale "No matching destinations" ~width]
     else List.drop matches t.view.top |> Fn.flip List.take (result_rows rows)
       |> List.mapi ~f:(fun i result ->
         let target = List.nth_exn t.items result.Fuzzy.Match.item in
         let selected = i + t.view.top = t.view.index in
         Tile_text.row (if selected then Pending else Status)
           (sprintf "%s%s:%s (line:character, %s)"
              (if selected then "> " else "  ") target.path (position target)
              (encoding target.encoding)) ~width))
  in
  { title = "Choose destination"
  ; footer = Some (Tile_shell.Label.footer ~notice ~pending:None
      ~default:(if hotkey_hints then "Tab/Shift-Tab select | Enter jump | Esc cancel"
                else "Enter jump | Esc cancel"))
  ; body = List.take body (Int.max 0 rows)
  }
;;
