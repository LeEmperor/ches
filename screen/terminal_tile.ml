open! Core
module M = Ches_terminal.Model

let id = Ches_tile.View_id.of_string "terminal"
let spec = Ches_tile.Spec.result_picker id ~title:"Terminal"

let placement ~width ~height =
  Floating.layout ~bounds:{ Geometry.Rect.x = 0; y = 0; width; height }
    ~preferred:{ width = 100; height = 30 } ~minimum:{ width = 20; height = 6 }
    ~policy:{ Tile_shell.Policy.minor with min_content_height = 4 }
;;

let render snapshot ~failure ~width ~rows : Tile_shell.Content.t =
  let body = List.init rows ~f:(fun y ->
    match snapshot with
    | None -> [ Span.blank Style.Backdrop width ]
    | Some (snapshot : M.snapshot) ->
      if y >= Array.length snapshot.rows then [ Span.blank Style.Backdrop width ]
      else (
        let row = snapshot.rows.(y) in
        let rec cells x acc =
          if x >= width then List.rev acc
          else if x >= Array.length row then List.rev (Span.blank Style.Backdrop (width - x) :: acc)
          else let cell = row.(x) in
            let style = Style.Terminal cell.style in
            if cell.width = 2 && x + 1 < width && x + 1 < Array.length row
            then cells (x + 2) (Span.create style cell.text ~width:2 :: acc)
            else if cell.width = 1
            then cells (x + 1) (Span.create style cell.text ~width:1 :: acc)
            else cells (x + 1) (Span.blank style 1 :: acc)
        in
        Span.merge (cells 0 []))) in
  let status = match failure, snapshot with
    | _, Some { exited = Some status; _ } -> "Exited: " ^ status ^ "; Ctrl-\\ Ctrl-r restarts"
    | Some error, Some _ -> "Input rejected: " ^ error ^ "; Ctrl-\\ Ctrl-n hides"
    | Some error, None -> "Failed: " ^ error ^ "; Ctrl-\\ Ctrl-r restarts"
    | _ -> "Ctrl-\\ Ctrl-n hides" in
  { title = "Terminal"; footer = Some (Tile_shell.Label.hint status); body }
;;

let cursor snapshot ~width ~rows =
  Option.bind snapshot ~f:(fun (s : M.snapshot) ->
    Option.some_if (s.cursor_visible && Option.is_none s.exited
      && s.cursor_col >= 0 && s.cursor_col < width && s.cursor_row >= 0 && s.cursor_row < rows)
      { Ches_tile.Cursor.column = s.cursor_col; row = s.cursor_row; shape = Block })
;;
