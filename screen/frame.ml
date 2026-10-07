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

module Floating_layer = struct
  type t =
    { id : Ches_tile.View_id.t
    ; layout : Tile_shell.Layout.t
    ; content : Tile_shell.Content.t
    ; cursor : Ches_tile.Cursor.t option
    }
end

type t =
  { width : int
  ; height : int
  ; rows : Span.t list list
  ; cursor : Cursor.t option
  ; smear : (int * int) list
  }
[@@deriving sexp_of]

let floating_layer ?allocation ?floating ui ~width ~height =
    match floating with
    | Some _ -> floating
    | None when Option.is_some allocation -> None
    | None when Option.is_some (Ui_state.content_picker ui) ->
      Option.bind (Ui_state.content_picker_layout ui ~width ~height) ~f:(fun layout ->
        Option.map (Ui_state.content_picker ui) ~f:(fun picker ->
          let content = layout.content in
          { Floating_layer.id = Content_picker_tile.id; layout
          ; content = Content_picker_tile.render ?notice:(Ui_state.capture_notice ui)
              picker ~width:content.width ~rows:content.height
          ; cursor = Some (Content_picker_tile.cursor picker ~width:content.width) }))
    | None when Option.is_some (Ui_state.line_picker ui) ->
      Option.bind (Ui_state.line_picker_layout ui ~width ~height) ~f:(fun layout ->
        Option.map (Ui_state.line_picker ui) ~f:(fun picker ->
          ignore (Line_picker_tile.validate picker (Ui_state.controller ui) : bool);
          let content = layout.content in
          { Floating_layer.id = Line_picker_tile.id
          ; layout
          ; content = Line_picker_tile.render ?notice:(Ui_state.capture_notice ui)
              picker ~width:content.width ~rows:content.height
          ; cursor = Some (Line_picker_tile.cursor picker ~width:content.width)
          }))
     | None when Option.is_some (Ui_state.file_picker ui) ->
       Option.bind (Ui_state.file_picker_layout ui ~width ~height) ~f:(fun layout ->
         Option.map (Ui_state.file_picker ui) ~f:(fun picker ->
           let content = layout.content in
           { Floating_layer.id = File_picker_tile.id
           ; layout
           ; content = File_picker_tile.render ?notice:(Ui_state.capture_notice ui)
               picker ~width:content.width ~rows:content.height
           ; cursor = Some (File_picker_tile.cursor picker ~width:content.width)
           }))
     | None ->
      Option.bind (Ui_state.palette_layout ui ~width ~height) ~f:(fun layout ->
        Option.map (Ui_state.palette ui) ~f:(fun palette ->
          let content = layout.content in
          { Floating_layer.id = Palette_tile.id
          ; layout
          ; content = Palette_tile.render ?notice:(Ui_state.capture_notice ui)
              palette ~width:content.width ~rows:content.height
          ; cursor = Some (Palette_tile.cursor palette ~width:content.width)
          }))
;;

let render_document ?highlights ?allocation ?reserve_status_row ?floating ui ~width ~height =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  let screen_width = width in
  let floating = floating_layer ?allocation ?floating ui ~width ~height in
  let floating_view =
    match floating with
    | Some layer -> Some (layer.id, Some layer.layout)
     | None when Option.is_some allocation ->
         Some ((if Option.is_some (Ui_state.content_picker ui) then Content_picker_tile.id
           else if Option.is_some (Ui_state.line_picker ui) then Line_picker_tile.id
          else if Option.is_some (Ui_state.file_picker ui) then File_picker_tile.id else Palette_tile.id), None)
    | None -> None
  in
  let explicit_allocation = Option.is_some allocation in
  let workspace = Ui_state.workspace ui ~width ~height in
  let buffers_in_status = not explicit_allocation && Ui_state.buffers_in_status ui ~width ~height in
  let pane_relative = Option.is_some allocation || Option.is_some workspace.status
    || not (List.is_empty workspace.minors)
    || Option.is_some (Ui_state.tab_rect ~buffers_in_status ui ~allocation:workspace.document.rect) in
  let minor_panes = if Option.is_some allocation then [] else workspace.minors in
  let allocation, default_reservation, status_pane =
    match allocation with
    | None -> workspace.document.rect, workspace.reserve_status_row, workspace.status
    | Some (rect : Geometry.Rect.t) ->
      let x = Int.clamp_exn rect.x ~min:0 ~max:width in
      let y = Int.clamp_exn rect.y ~min:0 ~max:height in
      let right = Int.clamp_exn (rect.x + Int.max 0 rect.width) ~min:x ~max:width in
      let bottom = Int.clamp_exn (rect.y + Int.max 0 rect.height) ~min:y ~max:height in
      { Geometry.Rect.x; y; width = right - x; height = bottom - y }, true, None
  in
  let reserve_status_row = Option.value reserve_status_row ~default:default_reservation in
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
  let geometry = Ui_state.geometry_in ~buffers_in_status ui ~allocation ~reserve_status_row in
  let scroll = Ui_state.fitted_scroll_in ~buffers_in_status ui ~allocation ~reserve_status_row in
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
  let buffers = Open_buffers.of_session (Ui_state.session ui) in
  let tab_row = Option.map (Ui_state.tab_rect ~buffers_in_status ui ~allocation) ~f:(fun rect ->
    rect, File_tabs.render buffers ~width:rect.width) in
  let directory = Session.input_directory (Ui_state.session ui) in
  let header = Option.map (Ui_state.directory_rect ~buffers_in_status ui ~allocation) ~f:(fun rect ->
    let d = Option.value_exn directory in
    let pending = if not (Ches_app.Directory_buffer.is_dirty d) then "" else
      match Ches_app.Directory_buffer.plan d with
      | Ok operations -> sprintf "* %d pending | " (List.length operations)
      | Error _ -> "* invalid plan | " in
    let label = if explicit_allocation then sprintf "%s%d marked | %s" pending (Set.length d.marks) (Directory_identity.encode_name d.path)
      else sprintf "Directory: %s%d marked | %s" pending (Set.length d.marks) (Directory_identity.encode_name d.path) in
    let label = String.prefix label rect.width in
    rect, [ Span.create Hint (label ^ String.make (rect.width - String.length label) ' ') ~width:rect.width ]) in
  (* Status and minor views share the tile shell; adapters fill its content area. *)
  let status_tile = Option.map status_pane ~f:(fun pane ->
    let layout = Tile_shell.layout Tile_shell.Policy.status pane.Workspace.Pane.rect in
    let body = Status_tile.body ~rect:layout.content fields
      (if buffers_in_status then buffers else []) in
    layout.outer,
    Array.of_list (Tile_shell.render layout ~focused:false { title = "Status"; footer = None; body }))
  in
  (* Each minor pane's content comes from its adapter; only the focused view shows the
     host's capture notice and pending prefix. *)
  let focused_view = Ui_state.focused_view ?floating:floating_view ui ~width ~height in
  let hotkey_hints = Ui_state.hotkey_hints ui in
  let minor_tiles = List.filter_map minor_panes ~f:(fun (pane : Workspace.Pane.t) ->
    match pane.id with
    | Document | Status -> None
    | Minor id when Ches_tile.View_id.equal id Ui_state.directory_id -> None
    | Minor id ->
      let layout =
        Option.value_exn (Ui_state.minor_layout ui ~width ~height id) in
      let width = layout.content.width and rows = layout.content.height in
      let focused = Ches_tile.View_id.equal focused_view id in
      let notice, pending =
        if focused then Ui_state.capture_notice ui, Ui_state.capture_pending ui else None, None in
      let content : Tile_shell.Content.t =
        match Ui_state.report ui with
        | _ when Ches_tile.View_id.equal id Problems_tile.id ->
          let tile = Ui_state.problems_tile ui in
          Problems.render
            ~hotkey_hints ~focused
            ~navigation:(Ui_state.problem_navigation ui ~width:screen_width ~height)
            ?details:(Problems_tile.text_view tile)
            ?notice ?pending
            (Controller.feedback (Ui_state.controller ui))
            ~current_document:(Problems_tile.current_document tile)
            ~document:(Problems_tile.document tile editor) ~width ~rows
        | _ when Ches_tile.View_id.equal id History_tile.id ->
          History_tile.render ~hotkey_hints ~focused ?notice ?pending (Ui_state.history_tile ui)
            (Ches_error.Error.history (Controller.feedback (Ui_state.controller ui)))
            ~width ~rows
        | Some report when Ches_tile.View_id.equal id Report_tile.id ->
          Report_tile.render ~hotkey_hints ~focused ?notice ?pending report ~width ~rows
        | Some _ | None -> { title = Ches_tile.View_id.to_string id; footer = None; body = [] }
      in
      Some (layout.outer, Array.of_list (Tile_shell.render layout ~focused content))) in
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
               (match directory with
                | Some d ->
                   let label = Option.value_map (Ches_app.Directory_buffer.row_at d line) ~default:"" ~f:(fun e ->
                      (if Option.exists (Ches_app.Directory_buffer.backing_entry d e) ~f:(fun entry -> Set.mem d.marks entry.id) then "*" else " ") ^
                     (match e.kind with File -> "f" | Directory -> "d" | Symlink -> "@" | Unsupported -> "!")) in
                  String.prefix (String.make (Int.max 0 (gutter.width - String.length label - 1)) ' ' ^ label ^ " ") gutter.width
                | None -> Line_numbers.label
                  (Ui_state.prefs ui).line_numbers
                  ~digits:gutter_digits
                  ~line
                  ~cursor_line)
              ~width:gutter.width
          ]
      in
      let text_spans =
         if Option.exists directory ~f:(fun d -> List.is_empty d.entries && not (Ches_app.Directory_buffer.is_dirty d)) && line = 0
            && Mode.equal (Editor.mode editor) Normal then
          let hint = String.prefix "(empty directory)" viewport.width in
          [ Span.create Hint (hint ^ String.make (viewport.width - String.length hint) ' ') ~width:viewport.width ]
        else if not exists
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
      let document =
        match header with
        | Some (rect, spans) when y = rect.y -> [ rect, spans ]
        | _ -> match tab_row, area_on_row Status_row y with
        | Some (rect, spans), _ when y = rect.y -> [ rect, spans ]
        | _, Some area -> [ area.rect, Status.render area fields ]
        | _, None when y >= tile.y && y < tile.y + tile.height -> [ tile, tile_row y ]
        | _, None -> []
      in
      let status = match status_tile with
        | Some (rect, rows) when y >= rect.y && y < rect.y + rect.height -> [ rect, rows.(y - rect.y) ]
        | Some _ | None -> []
      in
      let minors = List.filter_map minor_tiles ~f:(fun (rect, rows) ->
        if y >= rect.y && y < rect.y + rect.height then Some (rect, rows.(y - rect.y))
        else None) in
      let segments = List.sort (document @ status @ minors) ~compare:(fun (a, _) (b, _) -> Int.compare a.x b.x) in
      let spans, right = List.fold segments ~init:([], 0) ~f:(fun (spans, right) (rect, content) ->
        spans @ [ Span.blank Backdrop (rect.x - right) ] @ content, rect.x + rect.width)
      in
      Span.merge (spans @ [ Span.blank Backdrop (width - right) ]))
  in
  let rows =
    match floating with
    | None -> rows
    | Some layer ->
      let outer = layer.layout.outer in
      let layer_rows = Array.of_list (Tile_shell.render layer.layout
        ~focused:(Ches_tile.View_id.equal focused_view layer.id) layer.content) in
      List.mapi rows ~f:(fun y row ->
        if y < outer.y || y >= outer.y + outer.height
        then row
        else Span.overlay row ~x:outer.x ~width:outer.width layer_rows.(y - outer.y))
  in
  let animation = Ui_state.animation ui in
  let document_cursor =
    Option.exists (Ui_state.cursor_owner ?floating:floating_view ui ~width ~height)
      ~f:(Ches_tile.View_id.equal Ui_state.document_id) in
  let covered_by_float (x, y) =
    Option.exists floating ~f:(fun layer ->
      let rect = layer.layout.outer in
      x >= rect.x && x < rect.x + rect.width
      && y >= rect.y && y < rect.y + rect.height)
  in
  let smear =
    (if not document_cursor then [] else Animation.cells animation ~width ~height)
    |> List.filter ~f:(fun (x, y) ->
      not (covered_by_float (x, y))
      && (not pane_relative
          || (x >= viewport.x && x < viewport.x + viewport.width
              && y >= viewport.y && y < viewport.y + viewport.height)))
  in
  let cursor =
    if not document_cursor
    then
      (* A focused minor view's cursor, the one other terminal-cursor owner. *)
      let position =
        match floating with
        | Some layer when Option.exists
            (Ui_state.cursor_owner ?floating:floating_view ui ~width ~height)
            ~f:(Ches_tile.View_id.equal layer.id) ->
          Option.bind layer.cursor ~f:(fun intent ->
            let content = layer.layout.content in
            let x = content.x + intent.column and y = content.y + intent.row in
            Option.some_if
              (intent.column >= 0 && intent.column < content.width
               && intent.row >= 0 && intent.row < content.height
               && x >= 0 && x < width && y >= 0 && y < height)
              (x, y, intent.shape))
        | Some _ | None -> Ui_state.minor_cursor ?floating:floating_view ui ~width ~height
      in
      Option.map position ~f:(fun (x, y, shape) ->
        { Cursor.x
        ; y
        ; shape =
            (match (shape : Ches_tile.Cursor.Shape.t) with
             | Block -> Block
             | Bar -> Bar)
        })
    else if Animation.active animation || not (List.is_empty insert_points)
    then None
    else
       Option.map (Ui_state.cursor_position_in ~buffers_in_status ui ~allocation ~reserve_status_row) ~f:(fun (x, y) ->
        { Cursor.x = x
        ; y
        ; shape =
            (match Editor.mode editor with
             | Normal | Visual _ -> Block
             | Insert -> Bar)
        })
  in
  let cursor =
    Option.filter cursor ~f:(fun cursor ->
      cursor.x >= 0 && cursor.x < width && cursor.y >= 0 && cursor.y < height
      && (not document_cursor || not (covered_by_float (cursor.x, cursor.y))))
  in
  { width; height; rows; cursor; smear }
;;

let render ?highlights ?allocation ?reserve_status_row ?floating ui ~width ~height =
  if Ui_state.has_document ui then
    match allocation, Ui_state.side_layout ui ~width ~height with
    | None, Some layout ->
      let floating = floating_layer ?floating ui ~width ~height in
      let file = render_document ?highlights ?floating (Ui_state.surface ui ~directory:false) ~width ~height in
      let dir = render_document (Ui_state.surface ui ~directory:true)
        ~allocation:{ Geometry.Rect.x = 0; y = 0; width = layout.content.width; height = layout.content.height }
        ~reserve_status_row:false ~width:layout.content.width ~height:layout.content.height in
      let focused = Ches_tile.View_id.equal (Ui_state.focused_view ui ~width ~height) Ui_state.directory_id in
      let side = Tile_shell.render layout ~focused { title = "Directory"; footer = None; body = dir.rows } in
      (* The side pane is disjoint from the base document/status/band. Its omitted
         area is backdrop, so cutting that leading run must not introduce the
         clipping marker used by text labels ([Span.keep_right]). *)
      let rec drop_backdrop spans n = match spans with
        | [] -> []
        | span :: rest when n >= span.Span.width -> drop_backdrop rest (n - span.width)
        | span :: rest when n > 0 -> Span.blank span.style (span.width - n) :: rest
        | _ -> spans in
       let rows = List.mapi file.rows ~f:(fun y row ->
        if y < layout.outer.y || y >= layout.outer.y + layout.outer.height then row else
        let tail = drop_backdrop row (layout.outer.x + layout.outer.width) in
         Span.merge (Span.take row ~n:layout.outer.x @ List.nth_exn side (y - layout.outer.y) @ tail)) in
      (* Floats cover the entire workspace, including the directory side pane. *)
      let rows = match floating with
        | None -> rows
        | Some layer ->
          let outer = layer.layout.outer in
          let layer_rows = Array.of_list (Tile_shell.render layer.layout
            ~focused:(Ches_tile.View_id.equal (Ui_state.focused_view ui ~width ~height) layer.id)
            layer.content) in
          List.mapi rows ~f:(fun y row ->
            if y < outer.y || y >= outer.y + outer.height then row
            else Span.overlay row ~x:outer.x ~width:outer.width layer_rows.(y - outer.y)) in
      let cursor = if focused then Option.map (Ui_state.cursor_position ui ~width ~height) ~f:(fun (x, y) -> { Cursor.x; y; shape = Block }) else file.cursor in
      { file with rows; cursor; smear = (if focused then [] else file.smear) }
    | _ -> render_document ?highlights ?allocation ?reserve_status_row ?floating ui ~width ~height
  else
    let width = Int.max 0 width and height = Int.max 0 height in
    let messages =
      [ "No file open - Space q to quit"
      ; "Directory fallback: " ^ Ches_core.Directory_identity.encode_name (Session.startup_directory (Ui_state.session ui)) ] in
    let rows = List.init height ~f:(fun y ->
      let text = Option.value_map (List.nth messages y) ~default:"" ~f:(fun message -> String.prefix message width) in
      [ { Span.text = text ^ String.make (width - String.length text) ' '; width; style = Hint } ]) in
    { width; height; rows; cursor = None; smear = [] }
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
