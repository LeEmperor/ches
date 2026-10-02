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

let render ui ~width ~height =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  let editor = Controller.editor (Ui_state.controller ui) in
  let text = Editor.text editor in
  let line_count = Text_buffer.line_count text in
  let cursor_line = Editor.cursor_line editor in
  let geometry = Ui_state.geometry ui ~width ~height in
  let scroll = Ui_state.fitted_scroll ui ~width ~height in
  let { Geometry.tile
      ; border
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
  let small_word_class offset =
    if offset < 0 || offset >= Text_buffer.length text then None else
    let code = Uchar.to_scalar (Text_buffer.uchar_at text offset) in
    if code = 0x20 || code = 0x09 || code = 0x0A then None
    else if code >= 0x80 || Char.is_alphanum (Char.of_int_exn code) || code = Char.to_int '_'
    then Some `Identifier else Some `Punctuation
  in
  let is_match ~at query whole_word case_sensitive =
    let source = Text_buffer.to_string text in
    at + String.length query <= String.length source
    && String.for_alli query ~f:(fun i c ->
      let lower c =
        let n = Char.to_int c in
        if n >= Char.to_int 'A' && n <= Char.to_int 'Z' then Char.of_int_exn (n + 32) else c
      in
      if case_sensitive then Char.equal source.[at + i] c else Char.equal (lower source.[at + i]) (lower c))
    && (not whole_word
        || let class_ = small_word_class at in
           let before = if at = 0 then None else small_word_class (Option.value_exn (Text_buffer.prev_boundary text at)) in
           let stop = at + String.length query in
           let after = if stop = Text_buffer.length text then None else small_word_class stop in
           not ([%equal: [ `Identifier | `Punctuation ] option] class_ before)
           && not ([%equal: [ `Identifier | `Punctuation ] option] class_ after))
  in
  let matches =
    match search with
    | None -> []
    | Some (query, _, _, _) when String.is_empty query -> []
    | Some (query, whole_word, case_sensitive, current) ->
      let rec loop at acc =
        if at >= Text_buffer.length text then List.rev acc
        else
          let acc = if is_match ~at query whole_word case_sensitive then at :: acc else acc in
          loop (Option.value_exn (Text_buffer.next_boundary text at)) acc
      in
      loop 0 [] |> List.map ~f:(fun start -> start, String.length query, current)
  in
  let selection = Editor.selection editor in
  let area_on_row layout y =
    List.find areas ~f:(fun { rect; layout = l; _ } ->
      Geometry.Area.equal_layout l layout && y >= rect.y && y < rect.y + rect.height)
  in
  let rule n = String.concat (List.init n ~f:(fun _ -> "─")) in
  let tile_row y =
    let inner = viewport.width + gutter.width in
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
        then [ Span.blank Text viewport.width ]
        else (
          let text_style, special_style =
            if on_cursor_line
            then Style.Text_cursor_line, Style.Special_cursor_line
            else Text, Special
          in
           Span.of_glyphs
             (Cell_map.glyphs (Text_buffer.line_text text line))
            ~left:scroll.left
            ~cols:viewport.width
             ~text:text_style
             ~special:special_style
              ~highlight:(fun glyph ->
                let offset = Text_buffer.line_start text line + glyph.pos in
                match selection with
                | Some { Editor.Selection.anchor; active; kind = `Linewise } when line >= Int.min (Text_buffer.line_of_offset text anchor) (Text_buffer.line_of_offset text active) && line <= Int.max (Text_buffer.line_of_offset text anchor) (Text_buffer.line_of_offset text active) -> Some `Selection
                | Some { Editor.Selection.anchor; active; kind = `Characterwise } when offset >= Int.min anchor active && offset <= Int.max anchor active -> Some `Selection
                | _ -> List.find_map matches ~f:(fun (start, len, current) ->
                         Option.some_if (offset >= start && offset < start + len)
                            (if Option.value_map current ~default:false ~f:(Int.equal start) then `Current else `Match))))
      in
      let side = if border then [ Span.create Border "│" ~width:1 ] else [] in
      side @ gutter_spans @ text_spans @ side)
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
    if Animation.active animation
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
         sprintf !"%{sexp:Style.t}[%s]" s.style s.text)))
  |> String.concat ~sep:"\n"
;;
