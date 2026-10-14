open! Core
open Ches_core
open Ches_screen
open Helpers
module I = Cell_layout.Index

let%test_unit "window spans equal full-line oracle for clipping, overlays and absolute positions" =
  List.iter [ String.make 100_000 'x'
            ; String.concat (List.init 4000 ~f:(fun _ -> "中é\t\001\127\194\128\226\128\174"))
            ; String.make 255 'x' ^ String.concat (List.init 600 ~f:(fun _ -> "́")) ^ "中\tend" ] ~f:(fun s ->
    let text = Text_buffer.of_string ("prefix\n" ^ s) |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
    let layout = Text_buffer.line_layout text ~width:Cell_map.width 1 in
    let full = Cell_map.glyphs s in
    List.iter [0; 1; 7; 255; 256; 500; I.total_width layout - 100; I.total_width layout] ~f:(fun left ->
      let window = I.window layout ~left ~cols:160 in
      List.iter [ `None; `Character; `Block; `Search ] ~f:(fun overlay ->
        let highlight (g : Cell_map.Glyph.t) = match overlay with
          | `None -> None
          | `Character -> Option.some_if (g.pos >= left && g.pos < left + 60) `Selection
          | `Block -> Option.some_if (g.width > 0 && g.col < left + 90 && g.col + g.width > left + 2) `Selection
          | `Search -> Option.some_if (g.pos % 17 < 4) `Match in
        let syntax (g : Cell_map.Glyph.t) =
          if g.pos % 13 = 0 then Style.Syntax.Keyword else Plain in
        let draw glyphs = Span.of_glyphs glyphs ~left ~cols:160 ~syntax ~highlight
          ~text:(Style.document ()) ~special:(Style.document ~special:true ()) in
        assert (String.equal (Sexp.to_string ([%sexp_of: Span.t list] (draw window)))
                  (Sexp.to_string ([%sexp_of: Span.t list] (draw full)))))))
;;

let%test_unit "Frame geometry, navigation and repeated rendering have bounded warm work" =
  let t = ui (String.make 100_000 'x' ^ "\nshort") in
  let text = Editor.text (Ches_app.Controller.editor (Ui_state.controller t)) in
  let layout = Text_buffer.line_layout text ~width:Cell_map.width 0 in
  let before = I.steps layout in
  ignore (Frame.render t ~width:160 ~height:48);
  assert (I.steps layout - before < 500);
  let t = run ~width:160 ~height:48 t (keys "$") in
  let before = I.steps layout in
  for _ = 1 to 10 do ignore (Frame.render t ~width:160 ~height:48) done;
  assert (I.steps layout - before < 10 * 2500);
  let before = I.steps layout in
  ignore (run ~width:160 ~height:48 t (keys "hhhhhhhhhh"));
  assert (I.steps layout - before < 10 * 5000)
;;

let%test_unit "long-line visual/block rendering and beyond-EOL points" =
  List.iter ["$v20h"; "$<C-v>20h"; "$<C-v>20hj"; "<C-v>$jA"; "<C-v>ljI";
             "$i中<Esc>v20h"; "i中<Esc>$<C-v>20h"] ~f:(fun input ->
    let source = String.concat (List.init 1000 ~f:(fun _ -> "x\t中é\001")) ^ "\nshort\t中é" in
    let t = run ~width:160 ~height:8 (ui source) (keys input) in
    let editor = Ches_app.Controller.editor (Ui_state.controller t) in
    let text = Editor.text editor in
    let geometry = Ui_state.geometry t ~width:160 ~height:8 in
    let scroll = Ui_state.fitted_scroll t ~width:160 ~height:8 in
    let frame = Frame.render t ~width:160 ~height:8 in
    List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = 160));
    let styled = Frame.to_string_styled frame in
    assert (String.is_substring styled ~substring:(if String.is_suffix input ~suffix:"A" || String.is_suffix input ~suffix:"I" then "Insert" else "Selection"));
    List.iteri frame.rows ~f:(fun y spans ->
      let line = scroll.top + y - geometry.text.y in
      if y >= geometry.text.y && y < geometry.text.y + geometry.text.height
         && line < Text_buffer.line_count text then (
        let raw = Text_buffer.line_text text line in
        let glyphs = Cell_map.glyphs raw in
        let columns = Option.bind (Editor.block editor) ~f:(fun b ->
          Option.some_if (line >= b.first_line && line <= b.last_line) (Block.columns b glyphs)) in
        let point = List.Assoc.find (Editor.block_insert_points editor) line ~equal:Int.equal in
        let total = Cell_map.total_width glyphs in
        let glyphs = match point with
          | Some col when col >= total ->
            let blank kind col width = { Cell_map.Glyph.pos = String.length raw; col; width; text = String.make width ' '; kind } in
            Array.concat [glyphs; (if col > total then [|blank Tab total (col - total)|] else [||]); [|blank Plain col 1|]]
          | _ -> glyphs in
        let edges = (match columns with None -> [] | Some (l, r) -> [l; r])
                    @ (match point with None -> [] | Some col -> [col; col + 1]) in
        let glyphs = Array.concat_map glyphs ~f:(fun g ->
          if not (Cell_map.Kind.equal g.kind Tab) then [|g|] else
          let bounds = g.col :: (List.filter edges ~f:(fun c -> c > g.col && c < g.col + g.width)
                                |> List.dedup_and_sort ~compare:Int.compare) @ [g.col + g.width] in
          List.zip_exn (List.drop_last_exn bounds) (List.tl_exn bounds)
          |> List.map ~f:(fun (col, stop) -> {g with col; width = stop - col; text = String.make (stop - col) ' '})
          |> Array.of_list) in
        let highlight (g : Cell_map.Glyph.t) =
          match point with
          | Some col when g.width > 0 && g.col <= col && col < g.col + g.width ->
            Some (if line = fst (List.hd_exn (Editor.block_insert_points editor)) then `Insert_cursor else `Insert_point)
          | _ when g.pos >= String.length raw -> None
          | _ -> match Editor.selection editor with
            | Some {kind = `Blockwise; _} -> Option.bind columns ~f:(fun (left, stop) ->
                Option.some_if (g.width > 0 && g.col < stop && g.col + g.width > left) `Selection)
            | Some {kind = `Characterwise; anchor; active} ->
              let offset = Text_buffer.line_start text line + g.pos in
              Option.some_if (offset >= Int.min anchor active && offset <= Int.max anchor active) `Selection
            | _ -> None in
        let current_line = line = Editor.cursor_line editor in
        let expected = Span.of_glyphs glyphs ~left:scroll.left ~cols:geometry.text.width ~highlight
          ~text:(Style.document ~current_line ()) ~special:(Style.document ~current_line ~special:true ()) in
        let oracle_row = Span.overlay spans ~x:geometry.text.x ~width:geometry.text.width expected in
        assert (String.equal (Sexp.to_string ([%sexp_of: Span.t list] spans))
                  (Sexp.to_string ([%sexp_of: Span.t list] oracle_row))))))
;;
