open! Core
open Ches_screen
module P = Instance_picker_tile
module L = Ches_error.Language_query

let instance hier_path : L.instance = { hier_path; target = None }
let create items = P.create ~module_name:"leaf" ~active:(Some "top.wide") items
let text content = content.Tile_shell.Content.body |> List.concat
  |> List.map ~f:(fun span -> span.Span.text) |> String.concat
let selected t = Option.value_exn (P.selected t)

let%test_unit "active marker is independent of selection and search preserves records" =
  let narrow = instance "top.narrow" in
  let pos : L.position = { line = 12; character = 3 } in
  let range : L.range = { start = pos; stop = pos } in
  let wide = { (instance "top.wide") with target = Some
    { path = "/tmp/design.sv"; range; selection = range; encoding = Utf32 } } in
  let t = create [narrow; wide] in
  assert (L.equal_instance (selected t) narrow);
  let rendered = text (P.render t ~width:80 ~rows:5) in
  assert (String.is_substring rendered ~substring:">   top.narrow");
  assert (String.is_substring rendered ~substring:"  * top.wide");
  let t = P.update t ~rows:5 (Paste "wide") in
  assert (L.equal_instance (selected t) wide);
  assert (String.is_substring (text (P.render t ~width:80 ~rows:5)) ~substring:"> * top.wide");
  let missing = P.update t ~rows:5 (Paste "absent") in
  assert (Option.is_none (P.selected missing));
  assert (String.is_substring (text (P.render missing ~width:80 ~rows:5)) ~substring:"No matching instances");
  assert (Option.is_none (P.selected (create [])));
  assert (String.is_substring (text (P.render (create []) ~width:80 ~rows:5)) ~substring:"No instances")
;;

let%test_unit "navigation scrolling duplicate paths and Unicode query editing" =
  let items = List.init 30 ~f:(fun i -> instance (sprintf "top.inst%02d" i)) in
  let t = List.fold (List.init 20 ~f:Fn.id) ~init:(create items)
    ~f:(fun t _ -> P.update t ~rows:4 Next) in
  assert (L.equal_instance (selected (P.fit t ~rows:2)) (List.nth_exn items 20));
  assert (String.is_substring (text (P.render t ~width:80 ~rows:4)) ~substring:">   top.inst20");
  let t = P.update t ~rows:5 Previous in
  assert (L.equal_instance (selected t) (List.nth_exn items 19));
  let a = instance "top.界é" in
  let t = create [a; a] |> fun t -> P.update t ~rows:5 (Paste "界é") in
  assert (L.equal_instance (selected (P.update t ~rows:5 Next)) a);
  [%test_eq: string] (P.query (P.update t ~rows:5 Backspace)) "界";
  [%test_eq: string] (P.query (P.update t ~rows:5 Delete_word)) ""
;;

let%test_unit "tiny viewports and huge combining paths have bounded valid Unicode rendering" =
  let huge = "top.界é" ^ String.concat (List.init 500000 ~f:(fun _ -> "́")) in
  let t = P.create ~module_name:huge ~active:(Some huge) [instance huge] in
  List.iter [0; 1; 2; 3; 4; 5; 12; 80] ~f:(fun width ->
    List.iter [0; 1; 2; 8] ~f:(fun rows ->
      let rendered = P.render t ~width ~rows in
      assert (List.length rendered.body <= rows);
      assert (String.length rendered.title <= 32 + (16 * (width + 1)));
      List.iter rendered.body ~f:(fun spans ->
        assert (Span.total_width spans <= width);
        assert (List.sum (module Int) spans ~f:(fun span -> String.length span.Span.text)
                <= 32 * (width + 1));
        List.iter spans ~f:(fun span ->
          assert (Result.is_ok (Ches_core.Text_buffer.validate span.Span.text))));
      let cursor = P.cursor t ~width in
      assert (cursor.column >= 0 && cursor.column <= Int.max 0 (width - 1))));
  (* A small viewport must not copy/decode the million-byte path each frame. *)
  let before = Stdlib.Gc.allocated_bytes () in
  for _ = 1 to 10 do ignore (P.render t ~width:12 ~rows:3 : Tile_shell.Content.t) done;
  assert (Float.(Stdlib.Gc.allocated_bytes () - before < 1_000_000.))
;;
