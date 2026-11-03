open! Core
module L = Ches_error.Language_query
module Selection = Ches_tile.Navigation.Selection
module Query = Ches_palette.Query
module Fuzzy = Ches_palette.Fuzzy

let id = Ches_tile.View_id.of_string "instance-picker"
let spec = Ches_tile.Spec.result_picker id ~title:"Select active instance"

type t =
  { module_name : string
  ; active : Int.Set.t
  ; items : L.instance list
  ; query : string
  ; matches : int list
  ; view : int Selection.t
  }
[@@deriving sexp_of]

let result_rows rows = Int.max 1 (rows - 1)
let fit t ~rows =
  { t with view = Selection.fit t.view t.matches ~equal:Int.equal ~rows:(result_rows rows) }
;;

let create ~module_name ~active (items : L.instance list) =
  let active = List.filter_mapi items ~f:(fun i item ->
    Option.some_if (Option.exists active ~f:(String.equal item.L.hier_path)) i)
    |> Int.Set.of_list in
  fit { module_name; active; items; query = "";
        matches = List.mapi items ~f:(fun i _ -> i); view = Selection.empty } ~rows:1
;;
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
  let t = if String.equal query t.query then t else
    let matches = List.mapi t.items ~f:(fun i item ->
      i, [{ Fuzzy.Field.tag = (); text = item.L.hier_path; weight = 100 }])
      |> Fuzzy.rank ~query |> List.map ~f:(fun r -> r.Fuzzy.Match.item) in
    { t with query; matches; view = Selection.empty } in
  let t = fit t ~rows in
  match event with
  | Next | Previous ->
    { t with view = Selection.move t.view t.matches ~equal:Int.equal
        ~rows:(result_rows rows) (match event with Next -> Down | _ -> Up) }
  | _ -> t
;;

(* Bound decoded bytes as well as cells: combining marks cannot force a scan
   through a huge path. Do this before concatenation or span construction. *)
let bounded text ~width =
  let budget = 16 * (Int.min 65536 (Int.max 0 width) + 1) in
  if String.length text <= budget then text else
  let rec boundary pos =
    let next = pos + Stdlib.Uchar.utf_decode_length (Stdlib.String.get_utf_8_uchar text pos) in
    if next > budget then pos else boundary next
  in
  String.prefix text (boundary 0) ^ ">"
;;

let row style text ~width =
  if width <= 0 then [] else
  let budget = 16 * (Int.min 65536 width + 1) in
  let clipped = String.length text > budget in
  let spans = Tile_text.row style (bounded text ~width) ~width in
  if clipped then Span.take spans ~n:(width - 1) @ [Span.create Status_special ">" ~width:1]
  else spans
;;

let render ?(hotkey_hints = false) ?notice t ~width ~rows : Tile_shell.Content.t =
  let t = fit t ~rows in
  let body = if rows <= 0 then [] else
    Picker_text.query_row t.query ~width ::
    (if List.is_empty t.matches then
       [row Stale (if List.is_empty t.items then "No instances" else "No matching instances") ~width]
     else List.drop t.matches t.view.top |> Fn.flip List.take (result_rows rows)
       |> List.mapi ~f:(fun i index ->
         let item = List.nth_exn t.items index in
         let selected = i + t.view.top = t.view.index in
         let active = Set.mem t.active index in
         let prefix = (if selected then "> " else "  ") ^ (if active then "* " else "  ") in
         let path = row (if selected then Pending else Status) item.hier_path ~width:(Int.max 0 (width - 4)) in
         Span.take (Tile_text.row (if selected then Pending else Status) prefix ~width:(Int.min 4 width) @ path)
           ~n:(Int.max 0 width))) in
  { title = "Select active instance: " ^ bounded t.module_name ~width
  ; footer = Some (Tile_shell.Label.footer ~notice ~pending:None
      ~default:(if hotkey_hints then "* active | Tab/Shift-Tab select | Enter activate | Esc cancel"
                else "* active | Enter activate | Esc cancel"))
  ; body = List.take body (Int.max 0 rows)
  }
;;
