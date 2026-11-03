open! Core
module U = Ches_completion.User_snippets
module Selection = Ches_tile.Navigation.Selection
module Query = Ches_palette.Query
module Fuzzy = Ches_palette.Fuzzy

let id = Ches_tile.View_id.of_string "snippet-picker"
let spec = Ches_tile.Spec.result_picker id ~title:"Insert snippet"

type t =
  { items : U.item list
  ; query : string
  ; view : string Selection.t
  }
[@@deriving sexp_of]

let results t =
  List.map t.items ~f:(fun item ->
    let d = item.U.declaration in
    let field text weight = { Fuzzy.Field.tag = (); text; weight } in
    item, [ field d.prefix 100; field (Option.value d.description ~default:"") 90
          ; field d.id 80 ])
  |> Fuzzy.rank ~query:t.query
;;

let preview_rows rows = if rows >= 8 then Int.min 5 (rows / 2) else 0
let result_rows rows = Int.max 1 (rows - 1 - preview_rows rows)
let result_ids t = List.map (results t) ~f:(fun r -> r.Fuzzy.Match.item.U.declaration.id)

let fit t ~rows =
  { t with view = Selection.fit t.view (result_ids t) ~equal:String.equal ~rows:(result_rows rows) }
;;

let create items = fit { items; query = ""; view = Selection.empty } ~rows:1
let query t = t.query
let selected t =
  Option.bind t.view.selected ~f:(fun id ->
    List.find t.items ~f:(fun item -> String.equal item.U.declaration.id id))
;;

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
    { t with view = Selection.move t.view (result_ids t) ~equal:String.equal
        ~rows:(result_rows rows) (match event with Next -> Down | _ -> Up) }
  | _ -> t
;;

let origin = function U.Bundled -> "bundled" | Legacy_json -> "legacy JSON" | Ocaml -> "OCaml"

(* Do not map an entire 64 KiB line just to display a few cells. Bound bytes as
   well as cells, so even a line of combining marks stays cheap. Keep the normal
   Unicode-safe span clipping and explicitly mark a byte-budget truncation. *)
let preview_row text ~width =
  if width <= 0 then [] else
  let budget = 16 * (width + 1) in
  if String.length text <= budget then Tile_text.row Status text ~width else
  let rec boundary pos =
    let decode = Stdlib.String.get_utf_8_uchar text pos in
    let next = pos + Stdlib.Uchar.utf_decode_length decode in
    if next > budget then pos else boundary next
  in
  let prefix = String.prefix text (boundary 0) in
  (Tile_text.row Status prefix ~width |> Span.take ~n:(width - 1))
  @ [Span.create Status_special ">" ~width:1]
;;

let render ?(hotkey_hints = false) ?notice t ~width ~rows : Tile_shell.Content.t =
  let t = fit t ~rows in
  let results = results t in
  let result_body =
    if List.is_empty results then [ Tile_text.row Stale "No matching snippets" ~width ]
    else List.drop results t.view.top |> Fn.flip List.take (result_rows rows)
      |> List.mapi ~f:(fun i result ->
        let d = result.Fuzzy.Match.item.U.declaration in
        let selected = i + t.view.top = t.view.index in
        let description = Option.value_map d.description ~default:"" ~f:(fun s -> " — " ^ s) in
        Tile_text.row (if selected then Pending else Status)
          ((if selected then "> " else "  ") ^ d.prefix ^ description) ~width)
  in
  let preview = match selected t with
    | Some item when preview_rows rows > 0 ->
      let d = item.U.declaration in
      let scope = if List.is_empty d.scopes then "global" else String.concat ~sep:", " d.scopes in
      Tile_text.row Status ("ID: " ^ d.id) ~width
      :: Tile_text.row Status ("Scope: " ^ scope ^ " | Origin: " ^ origin item.origin) ~width
      :: (String.split_lines d.body |> Fn.flip List.take (preview_rows rows - 2)
           |> List.map ~f:(fun line -> preview_row line ~width))
    | _ -> []
  in
  let body = if rows <= 0 then [] else
    Picker_text.query_row t.query ~width :: result_body @ preview
    |> Fn.flip List.take rows in
  { title = "Insert snippet"
  ; footer = Some (Tile_shell.Label.footer ~notice ~pending:None
      ~default:(if hotkey_hints then "Tab/Shift-Tab select | Enter insert | Esc cancel"
                else "Enter insert | Esc cancel"))
  ; body }
;;
