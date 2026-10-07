open! Core
module Lines = Ches_line_picker.Lines
module Selection = Ches_tile.Navigation.Selection
let id = Ches_tile.View_id.of_string "line-picker"
let spec = Ches_tile.Spec.result_picker id ~title:"Document lines"
type t = { session : Lines.t; mutable view : int Selection.t }
let create controller = { session = Lines.create controller; view = Selection.empty }
let session t = t.session
let fit t ~rows =
  t.view <- Selection.fit { t.view with selected = Lines.selected t.session }
    (List.map (Lines.results t.session) ~f:(fun r -> r.line))
    ~equal:Int.equal ~rows:(Int.max 1 (rows - 2))
let interpret = File_picker_tile.interpret
let update t ~rows event = Lines.update t.session event; fit t ~rows
let work t ~budget = Lines.work t.session ~budget
let validate t controller = Lines.validate t.session controller
let accept t ~current ~release = Lines.accept t.session ~current ~release
let cancel t ~release = Lines.cancel t.session ~release
let cursor t ~width = Picker_text.cursor (Lines.query t.session) ~width
let row (result : Lines.result) ~selected ~width =
  let prefix = Span.of_text (sprintf "%s%d  " (if selected then "> " else "  ") result.line)
    ~style:Pending ~special:Status_special in
  let positions = Int.Set.of_list result.positions in
  (* Lay out the complete raw line before styling: TAB stops must not restart at
     every matched run. Glyph bytes and display columns stay separate. *)
  let text = Cell_map.glyphs result.text |> Array.to_list
    |> List.map ~f:(fun glyph -> Span.create
      (if Set.mem positions glyph.pos then Pending else Status) glyph.text ~width:glyph.width) in
  let spans = Span.keep_left (prefix @ text) ~n:(Int.max 0 width) ~marker_style:Status_special in
  Span.merge (spans @ [ Span.blank Status (Int.max 0 (width - Span.total_width spans)) ])
let render ?notice t ~width ~rows : Tile_shell.Content.t =
  fit t ~rows;
  let session = t.session in
  let status =
    if Lines.invalidated session then "Document changed; reopen line search"
    else if Lines.closed session then "Line search closed"
    else (if Lines.busy session then "Filtering... (Enter waits)" else "In-memory document (includes unsaved edits)")
      ^ (if Lines.truncated session then " | TRUNCATED: line/payload limit reached" else "")
  in
  let results = Lines.results session in
  let list =
    if List.is_empty results then [ Tile_text.row Stale
      (if Lines.invalidated session then "Results invalidated"
       else if Lines.busy session then "Filtering lines..." else "No matching lines") ~width ]
    else List.take (List.drop results t.view.top) (Int.max 0 (rows - 2))
      |> List.mapi ~f:(fun i result -> row result ~selected:(t.view.top + i = t.view.index) ~width)
  in
  let query = Picker_text.query_row (Lines.query session) ~width in
  let query = query @ [ Span.blank Status (Int.max 0 (width - Span.total_width query)) ] in
  { title = "Document lines | in-memory"
   ; footer = Some (Tile_shell.Label.hint (Option.value notice ~default:(sprintf "%d matches / %d lines | %s | Tab/Shift-Tab, Ctrl-n/p, Enter, Esc"
       (List.length results) (Lines.line_count session) status)))
  ; body = List.take (query :: Tile_text.row Stale status ~width :: list) (Int.max 0 rows) }
