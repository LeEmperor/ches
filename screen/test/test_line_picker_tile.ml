open! Core
open Ches_screen
open Ches_core
module Lines = Ches_line_picker.Lines
let controller text = Ches_app.Controller.create (Editor.create ~cell_width:Cell_map.width
  (Text_buffer.of_string text |> Result.ok |> Option.value_exn))
let drain t = while Lines.busy (Line_picker_tile.session t) do Line_picker_tile.work t ~budget:2 done
let text row = String.concat (List.map row ~f:(fun (s : Span.t) -> s.text))
let%expect_test "line numbers, match spans, tab layout, cursor, scrolling and tiny allocations" =
  let t = Line_picker_tile.create (controller "é\t界target\ntarget\ntarget\n") in
  Line_picker_tile.update t ~rows:4 (Paste "target"); drain t;
  let content = Line_picker_tile.render t ~width:40 ~rows:4 in
  assert (String.is_substring (text (List.nth_exn content.body 1)) ~substring:"In-memory");
  let row = List.nth_exn content.body 2 in
  assert (String.is_prefix (text row) ~prefix:"> 2  target");
  assert (List.exists row ~f:(fun s -> Style.equal s.style Pending && String.is_substring s.text ~substring:"target"));
  Line_picker_tile.update t ~rows:4 Next; Line_picker_tile.update t ~rows:4 Next;
  let content = Line_picker_tile.render t ~width:40 ~rows:4 in
  assert (String.is_prefix (text (List.nth_exn content.body 3)) ~prefix:"> 1  é       界target");
  List.iter [ -1; 0; 1; 2; 8; 40 ] ~f:(fun width ->
    List.iter [ -1; 0; 1; 2; 4; 8 ] ~f:(fun rows ->
      let content = Line_picker_tile.render t ~width ~rows in
      assert (List.length content.body <= Int.max 0 rows);
      List.iter content.body ~f:(fun row -> assert (Span.total_width row = Int.max 0 width));
      let cursor = Line_picker_tile.cursor t ~width in
      if width > 0 then assert (cursor.row = 0 && cursor.column >= 0 && cursor.column < width)));
  [%expect {| |}]
let%expect_test "truncation, invalidation and headless real controller acceptance" =
  let c = controller ("ok\n" ^ String.make 4097 'a') in
  let t = Line_picker_tile.create c in drain t;
  let content = Line_picker_tile.render t ~width:100 ~rows:4 in
  assert (String.is_substring (Option.value_exn content.footer).text ~substring:"TRUNCATED");
  assert (not (Line_picker_tile.validate t (controller "ok")));
  let content = Line_picker_tile.render t ~width:100 ~rows:4 in
  assert (String.is_substring (Option.value_exn content.footer).text ~substring:"Document changed");
  let c = controller "first\nneedle" in
  let t = Line_picker_tile.create c in
  Line_picker_tile.update t ~rows:4 (Paste "needle"); drain t;
  let released = ref false in
  let jumped = Line_picker_tile.accept t ~current:(fun () -> c)
    ~release:(fun () -> released := true) |> Or_error.ok_exn |> Option.value_exn in
  assert (!released && Editor.cursor_line (Ches_app.Controller.editor jumped) = 1);
  assert (match Line_picker_tile.interpret [ Ches_input.Key.Enter ] with Action Accept -> true | _ -> false);
  assert (match Line_picker_tile.interpret [ Ches_input.Key.Escape ] with Unbound -> true | _ -> false);
  [%expect {| |}]
