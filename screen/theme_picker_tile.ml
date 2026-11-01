open! Core
module Theme = Ches_theme.Theme
module Selection = Ches_tile.Navigation.Selection
module Query = Ches_palette.Query
module Fuzzy = Ches_palette.Fuzzy

let id = Ches_tile.View_id.of_string "theme-picker"
let spec = Ches_tile.Spec.result_picker id ~title:"Choose theme"

type t =
  { original : Theme.t
  ; preview : Theme.t
  ; query : string
  ; view : string Selection.t
  }
[@@deriving sexp_of]

let results t =
  List.map Theme.all ~f:(fun theme ->
    theme, [ { Fuzzy.Field.tag = (); text = Theme.title theme; weight = 100 } ])
  |> Fuzzy.rank ~query:t.query
;;

let fit t ~rows =
  let ids = List.map (results t) ~f:(fun r -> Theme.id r.Fuzzy.Match.item) in
  { t with view = Selection.fit t.view ids ~equal:String.equal ~rows:(Int.max 1 (rows - 1)) }
;;

let create theme =
  fit { original = theme; preview = theme; query = ""; view = { Selection.empty with selected = Some (Theme.id theme) } }
    ~rows:1
;;

let selected t = Option.bind t.view.selected ~f:Theme.find
let original t = t.original
let preview t = t.preview
let query t = t.query
let interpret = Palette_tile.interpret
let cursor t ~width = Picker_text.cursor t.query ~width

let update t ~rows (event : Ches_palette.Palette.Event.t) =
  let query = match event with
    | Insert c -> Query.append t.query (Uchar.Utf8.to_string c)
    | Paste text -> Query.append t.query text
    | Backspace -> Query.backspace t.query
    | Delete_word -> Query.delete_word t.query
    | Next | Previous -> t.query in
  let t = if String.equal query t.query then fit t ~rows
    else fit { t with query; view = (if String.is_empty query
      then { Selection.empty with selected = Some (Theme.id t.original) }
      else Selection.empty) } ~rows in
  let t = match event with
  | Next | Previous ->
    let ids = List.map (results t) ~f:(fun r -> Theme.id r.Fuzzy.Match.item) in
    { t with view = Selection.move t.view ids ~equal:String.equal ~rows:(Int.max 1 (rows - 1))
        (match event with Next -> Down | _ -> Up) }
  | _ -> t in
  { t with preview = Option.value (selected t) ~default:t.preview }
;;

let render ?(hotkey_hints = false) ?notice t ~width ~rows : Tile_shell.Content.t =
  let t = fit t ~rows in
  let results = results t in
  let body = if rows <= 0 then [] else
    Picker_text.query_row t.query ~width ::
    (if List.is_empty results then [ Tile_text.row Stale "No matching themes" ~width ]
     else List.drop results t.view.top |> Fn.flip List.take (Int.max 0 (rows - 1))
       |> List.mapi ~f:(fun i result ->
         let theme = result.Fuzzy.Match.item in
         let marker = if i + t.view.top = t.view.index then "> " else "  " in
         let kind = match Theme.kind theme with Dark -> "dark" | Light -> "light" in
         Tile_text.row (if i + t.view.top = t.view.index then Pending else Status)
           (sprintf "%s%s [%s]%s" marker (Theme.title theme) kind
              (if Theme.equal theme t.original then " *" else "")) ~width)) in
  { title = "Choose theme"
  ; footer = Some (Tile_shell.Label.footer ~notice ~pending:None
      ~default:(if hotkey_hints then "Tab/Shift-Tab preview | Enter apply | Esc cancel" else "Enter apply | Esc cancel"))
  ; body = List.take body (Int.max 0 rows)
  }
;;
