open! Core
open Ches_core
open Ches_app
open Ches_input

module Span = Span

module Cursor = struct
  type shape =
    | Block
    | Bar
  [@@deriving sexp_of, equal]

  type t =
    { x : int
    ; y : int
    ; shape : shape
    }
  [@@deriving sexp_of, equal]
end

type t =
  { width : int
  ; height : int
  ; rows : Span.t list list
  ; cursor : Cursor.t option
  ; smear : (int * int) list
  }
[@@deriving sexp_of]

let render ?highlights ui ~width ~height =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  let editor = Controller.editor (Ui_state.controller ui) in
  let text = Editor.text editor in
  let key, snapshot =
    Option.value highlights ~default:(Controller.highlights (Ui_state.controller ui))
  in
  let highlights =
    if Ches_highlight.Snapshot.matches snapshot key
       && Ches_highlight.Snapshot.Key.revision key = Editor.revision editor
    then Some snapshot else None
  in
  let line_count = Text_buffer.line_count text in
  let cursor_line = Editor.cursor_line editor in
  let geometry = Ui_state.geometry ui ~width ~height in
  let scroll = Ui_state.fitted_scroll ui ~width ~height in
  let { Geometry.tile
      ; border
      ; padding
      ; gutter
      ; gutter_digits
      ; text = viewport
      ; status = _
      ; offset = _
      ; areas
      }
    =
    geometry
  in
  let fields = Status.fields ui in
  let search =
    match Keymap.search_preview (Controller.keymap (Ui_state.controller ui)) with
    | Some query when not (String.is_empty query) -> Some (query, false, Editor.Search_case.(match Editor.search_case editor with Sensitive -> true | Insensitive -> false | Smart -> String.exists query ~f:(fun c -> Char.(c >= 'A' && c <= 'Z'))), None)
    | Some _ | None -> Editor.search_state editor
  in
  let matches =
    match search with
    | None -> []
    | Some (query, _, _, _) when String.is_empty query -> []
    | Some (query, whole_word, case_sensitive, current) ->
      if viewport.height <= 0 || viewport.width <= 0 || scroll.top >= line_count
      then []
      else
      let first = Text_buffer.line_start text scroll.top in
      let last_line = Int.min (line_count - 1) (scroll.top + viewport.height - 1) in
      let stop = Text_buffer.line_end text last_line in
      (* A multiline literal can begin above the viewport and still overlap it.
         Look back only far enough for such a match, aligned to UTF-8. *)
      let rec align at =
        if Text_buffer.is_boundary text at then at else align (at + 1)
      in
      let start = align (Int.max 0 (first - String.length query + 1)) in
      let rec loop at acc =
        if at >= stop then List.rev acc
        else
          let acc =
            if at + String.length query > first
               && Search_match.matches text ~query ~whole_word ~case_sensitive ~at
            then (at, String.length query, current) :: acc else acc
          in
          loop (Option.value_exn (Text_buffer.next_boundary text at)) acc
      in
      loop start []
  in
  let matches = Array.of_list matches in
  let search_highlighter first =
    (* Rows need not be constructed in screen order. Start each line with a
       binary lookup, then advance monotonically as its glyphs are visited. *)
    let rec lower_bound lo hi =
      if lo = hi then lo
      else
        let mid = lo + (hi - lo) / 2 in
        let start, len, _ = matches.(mid) in
        if start + len <= first then lower_bound (mid + 1) hi
        else lower_bound lo mid
    in
    let index = ref (lower_bound 0 (Array.length matches)) in
    fun offset ->
      while !index < Array.length matches
            && (let start, len, _ = matches.(!index) in start + len <= offset) do
        incr index
      done;
      if !index = Array.length matches then None
      else
        let start, _, current = matches.(!index) in
        if start > offset then None
        else Some (if Option.value_map current ~default:false ~f:(Int.equal start)
                   then `Current else `Match)
  in
  let selection = Editor.selection editor in
  let block = Editor.block editor in
  (* A block insert's points, all drawn as styled cells: the first, the cursor's own,
     in its own style, so that the theme can color it, which it cannot do for the
     terminal cursor (hidden meanwhile). They are never animated. *)
  let insert_points =
    List.mapi (Editor.block_insert_points editor) ~f:(fun i (line, col) ->
      line, (col, if i = 0 then `Insert_cursor else `Insert_point))
  in
  (* Blank cells up to and including a point past the line's end, so it can be drawn:
     before anything is typed, [A] can aim past a short line's end. *)
  let extend_to_point glyphs ~line_length point =
    let total = Cell_map.total_width glyphs in
    match point with
    | Some col when col >= total ->
      let blank ~kind col width =
        { Cell_map.Glyph.pos = line_length; col; width; text = String.make width ' '; kind }
      in
      Array.concat
        [ glyphs
        ; (if col > total then [| blank ~kind:Tab total (col - total) |] else [||])
        ; [| blank ~kind:Plain col 1 |]
        ]
    | Some _ | None -> glyphs
  in
  (* A block edge inside a TAB highlights only the TAB's cells within the block, so
     the TAB is drawn as separate runs of spaces at the edges. *)
  let split_tabs glyphs ~edges =
    Array.concat_map glyphs ~f:(fun (glyph : Cell_map.Glyph.t) ->
      match glyph.kind with
      | Plain | Escape -> [| glyph |]
      | Tab ->
        let stop = glyph.col + glyph.width in
        let cuts =
          List.filter edges ~f:(fun edge -> edge > glyph.col && edge < stop)
          |> List.dedup_and_sort ~compare:Int.compare
        in
        let bounds = (glyph.col :: cuts) @ [ stop ] in
        List.zip_exn (List.drop_last_exn bounds) (List.tl_exn bounds)
        |> List.map ~f:(fun (col, stop) ->
          { glyph with col; width = stop - col; text = String.make (stop - col) ' ' })
        |> Array.of_list)
  in
  let area_on_row layout y =
    List.find areas ~f:(fun { rect; layout = l; _ } ->
      Geometry.Area.equal_layout l layout && y >= rect.y && y < rect.y + rect.height)
  in
  let rule n = String.concat (List.init n ~f:(fun _ -> "─")) in
  let tile_row y =
    let inner = padding + gutter.width + viewport.width in
    if border && y = tile.y
    then (
      let top =
        match area_on_row Border_title y with
        | Some area -> Status.render area fields
        | None -> [ Span.create Border (rule inner) ~width:inner ]
      in
      [ Span.create Border "╭" ~width:1 ] @ top @ [ Span.create Border "╮" ~width:1 ])
    else if border && y = tile.y + tile.height - 1
    then [ Span.create Border ("╰" ^ rule inner ^ "╯") ~width:(inner + 2) ]
    else (
      let line = scroll.top + (y - viewport.y) in
      let on_cursor_line = line = cursor_line in
      let exists = line < line_count in
      (* Styled as text, so the cursor line's highlight runs across it. *)
      let padding_spans =
        if padding = 0
        then []
        else
          [ Span.blank (Style.document ~current_line:(exists && on_cursor_line) ()) padding ]
      in
      let gutter_spans =
        if gutter.width = 0
        then []
        else if not exists
        then [ Span.blank Gutter gutter.width ]
        else
          [ Span.create
              (if on_cursor_line then Gutter_cursor_line else Gutter)
              (Line_numbers.label
                 (Ui_state.prefs ui).line_numbers
                 ~digits:gutter_digits
                 ~line
                 ~cursor_line)
              ~width:gutter.width
          ]
      in
      let text_spans =
        if not exists
        then [ Span.blank (Style.document ()) viewport.width ]
        else (
          let text_style, special_style =
            Style.document ~current_line:on_cursor_line (),
            Style.document ~current_line:on_cursor_line ~special:true ()
          in
          let line_start = Text_buffer.line_start text line in
          let search_highlight = search_highlighter line_start in
          let line_text = Text_buffer.line_text text line in
          let line_length = String.length line_text in
          let syntax =
            Option.map highlights ~f:(fun snapshot ->
              let lookup = Ches_highlight.Snapshot.lookup_from snapshot line_start in
              fun (glyph : Cell_map.Glyph.t) ->
                if glyph.pos >= line_length then Style.Syntax.Plain
                else lookup (line_start + glyph.pos))
          in
          let glyphs = Cell_map.glyphs line_text in
          let block_columns =
            match block with
            | Some block when line >= block.first_line && line <= block.last_line ->
              Some (Block.columns block glyphs)
            | Some _ | None -> None
          in
          let point = List.Assoc.find insert_points line ~equal:Int.equal in
          let glyphs = extend_to_point glyphs ~line_length (Option.map point ~f:fst) in
          (* A point inside a TAB marks only its own cell. *)
          let edges =
            (match block_columns with
             | Some (left, stop) -> [ left; stop ]
             | None -> [])
            @ match point with
            | Some (col, _) -> [ col; col + 1 ]
            | None -> []
          in
          let glyphs = if List.is_empty edges then glyphs else split_tabs glyphs ~edges in
           Span.of_glyphs
              ?syntax
             glyphs
            ~left:scroll.left
            ~cols:viewport.width
             ~text:text_style
             ~special:special_style
              ~highlight:(fun glyph ->
                let offset = line_start + glyph.pos in
                match point with
                | Some (col, style)
                  when glyph.width > 0 && glyph.col <= col && col < glyph.col + glyph.width ->
                  Some style
                | Some _ | None when glyph.pos >= line_length -> None
                | Some _ | None ->
                match selection with
                | Some { kind = `Blockwise; _ } ->
                  (match block_columns with
                   | Some (left, stop)
                     when glyph.width > 0 && glyph.col < stop && glyph.col + glyph.width > left ->
                     Some `Selection
                   | Some _ | None -> search_highlight offset)
                | Some { Editor.Selection.anchor; active; kind = `Linewise } when line >= Int.min (Text_buffer.line_of_offset text anchor) (Text_buffer.line_of_offset text active) && line <= Int.max (Text_buffer.line_of_offset text anchor) (Text_buffer.line_of_offset text active) -> Some `Selection
                | Some { Editor.Selection.anchor; active; kind = `Characterwise } when offset >= Int.min anchor active && offset <= Int.max anchor active -> Some `Selection
                | _ -> search_highlight offset))
      in
      let side = if border then [ Span.create Border "│" ~width:1 ] else [] in
      side @ padding_spans @ gutter_spans @ text_spans @ side)
  in
  let rows =
    List.init height ~f:(fun y ->
      let row (rect : Geometry.Rect.t) spans =
        Span.merge
          ([ Span.blank Backdrop rect.x ]
           @ spans
           @ [ Span.blank Backdrop (width - rect.x - rect.width) ])
      in
      match area_on_row Status_row y with
      | Some area -> row area.rect (Status.render area fields)
      | None -> row tile (tile_row y))
  in
  let animation = Ui_state.animation ui in
  let smear = Animation.cells animation ~width ~height in
  let cursor =
    if Animation.active animation || not (List.is_empty insert_points)
    then None
    else
      Option.map (Ui_state.cursor_position ui ~width ~height) ~f:(fun (x, y) ->
        { Cursor.x = x
        ; y
        ; shape =
            (match Editor.mode editor with
             | Normal | Visual _ -> Block
             | Insert -> Bar)
        })
  in
  { width; height; rows; cursor; smear }
;;

let to_string t =
  let rows =
    List.map t.rows ~f:(fun spans ->
      String.concat (List.map spans ~f:(fun (s : Span.t) -> s.text)) ^ "|")
  in
  let cursor =
    match t.cursor with
    | None -> "cursor: none"
    | Some { x; y; shape } -> sprintf !"cursor: %d,%d %{sexp:Cursor.shape}" x y shape
  in
  String.concat ~sep:"\n" (rows @ [ cursor ])
;;

let to_string_styled t =
  List.map t.rows ~f:(fun spans ->
    String.concat
      ~sep:" "
      (List.map spans ~f:(fun (s : Span.t) ->
          sprintf "%s[%s]" (Style.to_string_hum s.style) s.text)))
  |> String.concat ~sep:"\n"
;;
