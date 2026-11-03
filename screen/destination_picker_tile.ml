open! Core
module L = Ches_error.Language_query
module Selection = Ches_tile.Navigation.Selection
module Query = Ches_palette.Query
module Fuzzy = Ches_palette.Fuzzy
module Preview = Ches_navigation_preview_model.Model

let id = Ches_tile.View_id.of_string "destination-picker"
let spec = Ches_tile.Spec.result_picker id ~title:"Choose destination"

type t =
  { items : L.target list
  ; title : string
  ; query : string
  ; view : int Selection.t
  ; preview : Preview.state option
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

let result_rows rows =
  if rows >= 8 then Int.min 6 (Int.max 3 (rows / 3)) else Int.max 1 (rows - 1)
let ids t = List.map (results t) ~f:(fun r -> r.Fuzzy.Match.item)
let fit t ~rows =
  { t with view = Selection.fit t.view (ids t) ~equal:Int.equal ~rows:(result_rows rows) }
;;
let create items = fit { items; title = "Choose destination"; query = ""; view = Selection.empty; preview = None } ~rows:1
let with_title t title = { t with title }
let selected t = Option.bind t.view.selected ~f:(List.nth t.items)
let selected_identity t = t.view.selected
let with_preview t preview = { t with preview }
let query t = t.query
let interpret = Palette_tile.interpret
let cursor t ~width = Picker_text.cursor t.query ~width

let update t ~rows (event : Ches_palette.Palette.Event.t) =
  let before = selected_identity t in
  let query = match event with
    | Insert c -> Query.append t.query (Uchar.Utf8.to_string c)
    | Paste text -> Query.append t.query text
    | Backspace -> Query.backspace t.query
    | Delete_word -> Query.delete_word t.query
    | Next | Previous -> t.query
  in
  let t = fit (if String.equal query t.query then t
               else { t with query; view = Selection.empty }) ~rows in
  let t = match event with
  | Next | Previous ->
    { t with view = Selection.move t.view (ids t) ~equal:Int.equal
        ~rows:(result_rows rows) (match event with Next -> Down | _ -> Up) }
  | _ -> t in
  if Option.equal Int.equal before (selected_identity t) then t
  else { t with preview = None }
;;

let encoding = function L.Utf8 -> "UTF-8" | Utf16 -> "UTF-16" | Utf32 -> "UTF-32"

let preview_line (line : Preview.line) ~number ~digits ~width =
  let prefix = sprintf "%*d │ " digits number in
  let margin = Tile_text.row Status_special prefix ~width:(Int.min width (digits + 3)) in
  let cols = Int.max 0 (width - digits - 3) in
  let glyphs = Cell_map.glyphs line.text in
  let selected pos = List.exists line.highlights ~f:(fun h ->
    if h.start = h.stop then pos = h.start else h.start <= pos && pos < h.stop) in
  let spans = Span.of_glyphs glyphs ~left:0 ~cols
      ~text:(Style.document ()) ~special:(Style.document ())
      ~highlight:(fun glyph -> if selected glyph.pos then Some `Selection else None) in
  let spans =
    if selected (String.length line.text) then (
      let x = Cell_map.total_width glyphs in
      if x < cols then Span.overlay spans ~x ~width:1
          [Span.blank (Style.document ~overlay:Selection ()) 1] else spans)
    else spans in
  let spans = if line.truncated && cols > 0 then
      Span.overlay spans ~x:(cols - 1) ~width:1 [Span.create Status_special ">" ~width:1]
    else spans in
  margin @ spans
;;

let preview_rows t ~width ~rows =
  if rows <= 0 then [] else
  let header, body = match t.preview with
    | None -> "Source preview", []
    | Some (Ready payload) ->
      let origin = match payload.source with
        | Buffer { revision } -> sprintf "buffer r%d" revision
        | Disk _ -> "disk" in
      let header = sprintf "Source preview (%s%s)" origin
          (if payload.truncated then "; truncated" else "") in
      let digits = String.length (Int.to_string (payload.first_line + List.length payload.lines)) in
      let available = Int.max 0 (rows - 1) in
      let target_line = Option.value_map (selected t) ~default:payload.first_line
          ~f:(fun target -> target.L.selection.start.line) in
      let drop = Int.max 0 (target_line - payload.first_line - Int.max 0 (available / 2)) in
      header, (List.drop payload.lines drop |> Fn.flip List.take available
        |> List.mapi ~f:(fun i line -> preview_line line
            ~number:(payload.first_line + drop + i + 1) ~digits ~width))
    | Some state ->
      let message = match state with
        | Loading -> "Loading source…"
        | Missing -> "Source file missing"
        | Unreadable reason -> "Unreadable: " ^ String.prefix reason 512
        | Unsupported reason -> "Unsupported: " ^ String.prefix reason 512
        | Limit reason -> "Preview limit: " ^ String.prefix reason 512
        | Invalid_target reason -> "Invalid target: " ^ String.prefix reason 512
        | Cancelled -> "Preview cancelled"
        | Ready _ -> assert false in
      "Source preview", [Tile_text.row Stale message ~width]
  in
  Tile_text.row Status_special header ~width :: body
;;

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
  let body = if rows < 8 then body else
      let list_rows = 1 + result_rows rows in
      let body = List.init list_rows ~f:(fun i ->
        Option.value (List.nth body i) ~default:(Tile_text.row Status "" ~width)) in
      body @ preview_rows t ~width ~rows:(rows - list_rows) in
  let count = sprintf "%d/%d" (List.length matches) (List.length t.items) in
  { title = sprintf "%s (%s)" t.title count
  ; footer = Some (Tile_shell.Label.footer ~notice ~pending:None
      ~default:(count ^ " | " ^ (if hotkey_hints then "Tab/Shift-Tab select | Enter jump | Esc cancel"
                else "Enter jump | Esc cancel")))
  ; body = List.take body (Int.max 0 rows)
  }
;;
