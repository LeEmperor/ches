open! Core
open Ches_core
module I = Cell_layout.Index

let buffer s = Text_buffer.of_string s |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith

let%test_unit "checkpoint geometry equals full layout, including combining boundaries" =
  List.iter [ String.make 100_000 'x'
            ; String.concat (List.init 2000 ~f:(fun _ -> "中é\t\001\127\194\128\226\128\174"))
            ; String.make 255 'x' ^ String.concat (List.init 600 ~f:(fun _ -> "́")) ^ "中\tend"
            ; "́́"; "" ] ~f:(fun s ->
    let text = buffer ("prefix\n" ^ s ^ "\nend") in
    let layout = Text_buffer.line_layout text ~width:Cell_width.f 1 in
    let full = Cell_layout.glyphs ~width:Cell_width.f s in
    assert (I.total_width layout = Cell_layout.total_width full);
    Array.iteri full ~f:(fun i g ->
      if i % 97 = 0 || g.width = 0 then (
        assert (I.scalar_column layout ~pos:g.pos = i);
        assert (I.pos_of_scalar_column layout i = g.pos);
        assert (Text_buffer.column_of_offset text (Text_buffer.line_start text 1 + g.pos) = i);
        assert (Text_buffer.offset_of_column text ~line:1 i = Text_buffer.line_start text 1 + g.pos);
        List.iter [true; false] ~f:(fun insertion ->
          assert (Poly.equal (I.cursor_span layout ~pos:g.pos ~insertion)
                    (Cell_layout.cursor_span full ~pos:g.pos ~insertion)));
        List.iter [true; false] ~f:(fun tab_end ->
          assert (I.column layout ~pos:g.pos ~tab_end = Cell_layout.column full ~pos:g.pos ~tab_end))));
    assert (Poly.equal (I.cursor_span layout ~pos:(String.length s) ~insertion:false)
              (Cell_layout.cursor_span full ~pos:(String.length s) ~insertion:false));
    List.iter [0; 1; 7; 8; 255; 256; 1000; I.total_width layout - 1; I.total_width layout] ~f:(fun col ->
      assert (Poly.equal (I.pos_of_column layout col) (Cell_layout.pos_of_column full col)));
    assert (I.checkpoint_count layout <= 256))
;;

let%test_unit "bounded seeking and viewport allocation, snapshot and width identities" =
  let text = buffer (String.make 100_000 'x') in
  let layout = Text_buffer.line_layout text ~width:Cell_width.f 0 in
  let before = I.steps layout in
  assert (Array.length (I.window layout ~left:0 ~cols:160) = 160);
  assert (I.steps layout - before <= 161);
  ignore (I.window layout ~left:99_800 ~cols:160);
  let before = I.steps layout in
  for _ = 1 to 20 do
    ignore (I.window layout ~left:99_700 ~cols:160);
    ignore (I.cursor_span layout ~pos:99_750 ~insertion:false)
  done;
  assert (I.steps layout - before <= 20 * (2 * 400 + 162));
  assert (phys_equal layout (Text_buffer.line_layout text ~width:Cell_width.f 0));
  let edited = Text_buffer.insert text ~at:0 "中" |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
  let changed = Text_buffer.line_layout edited ~width:Cell_width.f 0 in
  assert (not (phys_equal layout changed));
  assert (I.column changed ~pos:3 ~tab_end:false = 2);
  let other_width _ = 3 in
  let other = Text_buffer.line_layout text ~width:other_width 0 in
  assert (not (phys_equal layout other));
  assert (I.column other ~pos:1 ~tab_end:false = 3);
  let many = buffer (String.concat ~sep:"\n" (List.init 70 ~f:(fun _ -> "x"))) in
  let first = Text_buffer.line_layout many ~width:Cell_width.f 0 in
  for line = 1 to 69 do ignore (Text_buffer.line_layout many ~width:Cell_width.f line) done;
  assert (not (phys_equal first (Text_buffer.line_layout many ~width:Cell_width.f 0)))
;;
