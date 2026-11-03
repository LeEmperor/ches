open! Core
module M = Ches_terminal.Model
module T = Ches_tile.Text_view

type inspection =
  { snapshot : M.snapshot option
  ; text : T.t
  ; width : int
  ; starts : int array
  ; block_anchor : int option
  }

let inspect snapshot =
  let screen = Option.value_map snapshot ~default:[||] ~f:(fun (s : M.snapshot) -> s.rows) in
  let lines = Array.map screen ~f:(fun row ->
    String.concat (Array.to_list (Array.filter_map row ~f:(fun (c : M.cell) ->
      Option.some_if (c.width > 0) c.text)))) in
  let offset = ref 0 in
  let starts = Array.map lines ~f:(fun line ->
    let start = !offset in offset := start + String.length line + 1; start) in
  let width = Array.fold screen ~init:1 ~f:(fun w row -> Int.max w (Array.length row)) in
  let text = T.create ~cell_width:Cell_map.width (String.concat ~sep:"\n" (Array.to_list lines)) in
  let text = Option.value_map snapshot ~default:text ~f:(fun s ->
    if s.cursor_row < 0 || s.cursor_row >= Array.length screen then text else
      let col = ref 0 in
      Array.iteri screen.(s.cursor_row) ~f:(fun x c ->
        if c.width > 0 && x + c.width <= s.cursor_col then col := !col + String.length c.text);
      T.jump text (starts.(s.cursor_row) + !col)) in
  { snapshot; text; width; starts; block_anchor = None }
;;

let inspection_text t = t.text

type block_selection =
  { first_row : int; last_row : int; left : int; right : int }
[@@deriving sexp_of, equal]

let block_selection t =
  Option.map t.block_anchor ~f:(fun anchor ->
    let corner text =
      let row, col = T.cursor_cell text ~width:t.width in
      let width = Option.value_map t.snapshot ~default:1 ~f:(fun s ->
        if row < Array.length s.rows && col < Array.length s.rows.(row)
        then Int.max 1 s.rows.(row).(col).width else 1) in
      row, col, col + width in
    let ar, ac, az = corner (T.jump t.text anchor) in
    let br, bc, bz = corner t.text in
    { first_row = Int.min ar br; last_row = Int.max ar br
    ; left = Int.min ac bc; right = Int.max az bz })
;;

let in_block b ~row ~col ~width =
  row >= b.first_row && row <= b.last_row && col < b.right && col + width > b.left
;;

let toggle_block t ~rows =
  match t.block_anchor with
  | Some _ ->
    let text, _ = T.perform t.text ~width:t.width ~rows Exit_visual in
    { t with text; block_anchor = None }
  | None ->
    (* A latent characterwise Visual lets Text_view retain its anchor and handle
       motions, counts, Escape and endpoint swapping. Only the grid rectangle is
       displayed/copied while block_anchor is present. *)
    let text = match T.visual t.text with
      | Some Characterwise -> t.text
      | None | Some Linewise -> fst (T.perform t.text ~width:t.width ~rows (Visual Characterwise)) in
    let swapped, _ = T.perform text ~width:t.width ~rows Swap_ends in
    { t with text; block_anchor = Some (T.cursor swapped) }
;;

let yank_block t b =
  let width = ref (b.right - b.left) in
  let lines = List.init (b.last_row - b.first_row + 1) ~f:(fun i ->
    let row = b.first_row + i in
    let cells = Option.value_map t.snapshot ~default:[||] ~f:(fun s ->
      if row < Array.length s.rows then s.rows.(row) else [||]) in
    let selected_width = ref 0 in
    let text = Array.filter_mapi cells ~f:(fun col (cell : M.cell) ->
      if cell.width > 0 && in_block b ~row ~col ~width:cell.width then (
        selected_width := !selected_width + cell.width; Some cell.text)
      else None) |> Array.to_list |> String.concat in
    width := Int.max !width !selected_width;
    text) in
  let offset = if b.first_row < Array.length t.starts then
    let cells = (Option.value_exn t.snapshot).rows.(b.first_row) in
    let bytes = ref 0 in
    Array.iteri cells ~f:(fun col c ->
      if c.width > 0 && col + c.width <= b.left then bytes := !bytes + String.length c.text);
    t.starts.(b.first_row) + !bytes
    else 0 in
  let text = T.jump t.text offset in
  let effect = if List.for_all lines ~f:String.is_empty then T.Effect.Notice "nothing to copy"
    else T.Effect.Copy (Ches_core.Register.Block { rows = lines; width = !width }) in
  { t with text; block_anchor = None }, Some effect
;;

let perform t ~rows action =
  match t.block_anchor, action with
  | Some _, (T.Action.Yank | Yank_line) -> yank_block t (Option.value_exn (block_selection t))
  | Some _, Visual Characterwise -> { t with block_anchor = None }, None
  | anchor, _ ->
    let text, effect = T.perform t.text ~width:t.width ~rows action in
    let block_anchor = match action with
      | Exit_visual | Visual _ -> None
      | Swap_ends -> Option.map anchor ~f:(fun _ -> T.cursor t.text)
      | _ -> anchor in
    { t with text; block_anchor }, effect
;;

(* Keep the frozen grid's logical rows intact on resize. A narrower float clips
   horizontally around the inspection cursor instead of reflowing shell output. *)
let inspection_left t ~width =
  let row, column = T.cursor_cell t.text ~width:t.width in
  let glyph_width = Option.value_map t.snapshot ~default:1 ~f:(fun s ->
    if row < Array.length s.rows && column < Array.length s.rows.(row)
    then Int.max 1 s.rows.(row).(column).width else 1) in
  Int.max 0 (column - Int.max 1 width + glyph_width)
;;

let id = Ches_tile.View_id.of_string "terminal"
let spec = Ches_tile.Spec.result_picker id ~title:"Tile Terms"
let default_size : Floating.Size.t = { width = 200; height = 60 }

let placement_with_preferred ~preferred ~width ~height =
  Floating.layout ~bounds:{ Geometry.Rect.x = 0; y = 0; width; height }
    ~preferred ~minimum:{ width = 20; height = 6 }
    ~policy:{ Tile_shell.Policy.minor with min_content_height = 4 }
;;

let placement ~width ~height =
  placement_with_preferred ~preferred:default_size ~width ~height
;;

let render ?(hotkey_hints = false) ?(number = 1) ?inspection snapshot ~failure ~width ~rows : Tile_shell.Content.t =
  let live_snapshot = snapshot in
  let snapshot = Option.value_map inspection ~default:snapshot ~f:(fun t -> t.snapshot) in
  let top = Option.value_map inspection ~default:0 ~f:(fun t ->
    T.top (T.fit t.text ~width:t.width ~rows)) in
  let left = Option.value_map inspection ~default:0 ~f:(fun t -> inspection_left t ~width) in
  let stop = left + width in
  let body = List.init rows ~f:(fun y ->
    let y = y + top in
    match snapshot with
    | None -> [ Span.blank Style.Backdrop width ]
    | Some (snapshot : M.snapshot) ->
      if y >= Array.length snapshot.rows then [ Span.blank Style.Backdrop width ]
      else (
        let row = snapshot.rows.(y) in
        let byte = ref (Option.value_map inspection ~default:0 ~f:(fun t -> t.starts.(y))) in
        let selection = Option.bind inspection ~f:(fun t -> T.selection t.text) in
        let block = Option.bind inspection ~f:block_selection in
        let rec cells x acc =
          if x >= stop then List.rev acc
          else if x >= Array.length row then List.rev (Span.blank Style.Backdrop (stop - Int.max left x) :: acc)
          else let cell = row.(x) in
            let selected = match block with
              | Some b ->
                let col = if cell.width = 0 then Int.max 0 (x - 1) else x in
                let width = if cell.width = 0 then Int.max 1 row.(col).width else cell.width in
                in_block b ~row:y ~col ~width
              | None -> Option.exists selection ~f:(fun (a, b) -> !byte < b && !byte + String.length cell.text > a) in
            let style = if selected then Style.document ~overlay:Selection () else Style.Terminal cell.style in
            byte := !byte + String.length cell.text;
            if x < left then cells (x + 1) acc
            else if cell.width = 2 && x + 1 < stop && x + 1 < Array.length row
            then cells (x + 2) (Span.create style cell.text ~width:2 :: acc)
            else if cell.width = 1
            then cells (x + 1) (Span.create style cell.text ~width:1 :: acc)
            else cells (x + 1) (Span.blank style 1 :: acc)
        in
        Span.merge (cells 0 []))) in
  let mode = match inspection with
    | None -> "INSERT" ^ (if hotkey_hints then " | Ctrl-Space/jk: Normal (Escape passes through)" else "")
    | Some t -> (if Option.is_some t.block_anchor then "VISUAL BLOCK"
      else if Option.is_some (T.visual t.text) then "VISUAL" else "NORMAL")
      ^ (if hotkey_hints then " | Space /: hide  +/-: size  Space t r: reset  i/a: Insert  v/V/C-v: select  y/yy: yank" else "") in
  let restart = if hotkey_hints then " | r: restart" else "" in
  let status = match failure, live_snapshot with
    | _, Some { exited = Some status; _ } -> "Exited: " ^ status ^ restart ^ " | " ^ mode
    | Some error, None -> "Failed: " ^ error ^ restart ^ " | " ^ mode
    | Some error, Some _ -> "Input rejected: " ^ error ^ " | " ^ mode
    | _ -> mode in
  { title = sprintf "Tile Term %d" number; footer = Some (Tile_shell.Label.hint status); body }
;;

let cursor ?inspection snapshot ~width ~rows =
  match inspection with
  | Some t ->
    let text = T.fit t.text ~width:t.width ~rows in
    let row, column = T.cursor_cell text ~width:t.width in
    let row = row - T.top text in
    let column = column - inspection_left t ~width in
    Option.some_if (column >= 0 && column < width && row >= 0 && row < rows)
      { Ches_tile.Cursor.column; row; shape = Block }
  | None -> Option.bind snapshot ~f:(fun (s : M.snapshot) ->
    Option.some_if (s.cursor_visible && Option.is_none s.exited
      && s.cursor_col >= 0 && s.cursor_col < width && s.cursor_row >= 0 && s.cursor_row < rows)
      { Ches_tile.Cursor.column = s.cursor_col; row = s.cursor_row; shape = Block })
;;
