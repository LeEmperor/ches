open! Core
open Ches_core
module Controller = Ches_app.Controller
module Lines = Ches_line_picker.Lines
let width u = match Uchar.to_scalar u with 0x754c -> 2 | 0x301 -> 0 | _ -> 1
let controller text =
  Controller.create (Editor.create ~path:"/nonexistent/unsaved.txt" ~cell_width:width
    (Text_buffer.of_string text |> Result.ok |> Option.value_exn))
let command t command =
  let t, _, _ = Controller.dispatch t [ Ches_input.Keymap.Action.Editor command ] in t
let drain t = while Lines.busy t do Lines.work t ~budget:2 done
let search t query = Lines.update t (Paste query); drain t
let%expect_test "in-memory dirty contents, duplicates, trailing empty line, once-only release then jump" =
  let c = controller "saved" in
  let c = command c (Enter_insert Before_cursor) |> fun c -> command c (Insert_text "needle\nneedle\n") in
  let c = command c Exit_insert in
  assert (Editor.is_dirty (Controller.editor c));
  let t = Lines.create c in
  search t "ndl";
  assert (List.equal Int.equal (List.map (Lines.results t) ~f:(fun r -> r.line)) [ 1; 2 ]);
  Lines.update t Next;
  let released = ref 0 in
  let result = Lines.accept t ~current:(fun () -> c) ~release:(fun () -> incr released) |> Or_error.ok_exn |> Option.value_exn in
  assert (!released = 1 && Editor.cursor_line (Controller.editor result) = 1);
  assert (phys_equal (Editor.text (Controller.editor c)) (Editor.text (Controller.editor result)));
  assert (Editor.is_dirty (Controller.editor result));
  assert (Option.is_none (Lines.accept t ~current:(fun () -> c) ~release:(fun () -> assert false) |> Or_error.ok_exn));
  let t = Lines.create (controller "same\nsame\n") in drain t;
  assert (List.equal Int.equal (List.map (Lines.results t) ~f:(fun r -> r.line)) [ 1; 2; 3 ]);
  [%expect {| |}]
let%expect_test "Unicode display columns, tabs, wide/control glyphs and combining policy" =
  List.iter [ "é\t界target", "target", 6
            ; "é\t界target", "界", 3
            ; "é\001界target", "target", 6
            ; "étarget", "́", 0 ] ~f:(fun (text, query, expected) ->
    let c = controller text in
    let t = Lines.create c in search t query;
    let result = Lines.accept t ~current:(fun () -> c) ~release:ignore |> Or_error.ok_exn |> Option.value_exn in
    assert (Editor.cursor (Controller.editor result) = expected));
  let e = Controller.editor (controller "界") in
  assert (Or_error.is_error (Editor.display_position_of_offset e 1));
  assert (Tuple2.equal ~eq1:Int.equal ~eq2:Int.equal (Or_error.ok_exn (Editor.display_position_of_offset e 0)) (1, 1));
  [%expect {| |}]
let%expect_test "identity and revisions invalidate; release revalidation, pending/empty/cancel inert" =
  let c = controller "same" in
  let other = controller "same" in
  let t = Lines.create c in drain t;
  assert (not (Lines.validate t other) && Lines.invalidated t);
  assert (List.is_empty (Lines.results t));
  assert (Or_error.is_error (Lines.accept t ~current:(fun () -> other) ~release:(fun () -> assert false)));
  let edited = command c (Enter_insert Before_cursor) |> fun c -> command c (Insert_text "x") |> fun c -> command c Exit_insert in
  let undone = command edited Undo in
  assert (Text_buffer.equal (Editor.text (Controller.editor c)) (Editor.text (Controller.editor undone)));
  let t = Lines.create c in drain t;
  assert (not (Lines.validate t undone));
  let branch = command c (Enter_insert Before_cursor) |> fun c -> command c (Insert_text "y") |> fun c -> command c Exit_insert in
  assert (Editor.revision (Controller.editor branch) = Editor.revision (Controller.editor edited));
  let t = Lines.create edited in drain t;
  assert (not (Lines.validate t branch));
  let t = Lines.create c in drain t;
  let current = ref c in
  assert (Or_error.is_error (Lines.accept t ~current:(fun () -> !current) ~release:(fun () -> current := other)));
  assert (Lines.closed t);
  let t = Lines.create c in
  assert (Option.is_none (Lines.accept t ~current:(fun () -> c) ~release:(fun () -> assert false) |> Or_error.ok_exn));
  search t "no match";
  assert (Option.is_none (Lines.accept t ~current:(fun () -> c) ~release:(fun () -> assert false) |> Or_error.ok_exn));
  let releases = ref 0 in Lines.cancel t ~release:(fun () -> incr releases);
  Lines.cancel t ~release:(fun () -> assert false);
  assert (!releases = 1);
  [%expect {| |}]
let%expect_test "count and payload truncation are visible, bounded preparation across queries" =
  List.iter [ String.concat ~sep:"\n" (List.init 50_001 ~f:(fun _ -> "x")), 50_000
            ; String.concat ~sep:"\n" (List.init 2050 ~f:(fun _ -> String.make 4096 'a')), 2048 ]
    ~f:(fun (text, expected) ->
      let t = Lines.create (controller text) in
      while Lines.busy t do
        let before = Lines.prepared_count t in
        Lines.work t ~budget:128;
        assert (Lines.prepared_count t - before <= 128)
      done;
      assert (Lines.truncated t && Lines.prepared_count t = expected);
      assert (List.length (Lines.results t) = expected);
      search t "z";
      assert (List.is_empty (Lines.results t) && Lines.prepared_count t = expected));
  [%expect {| |}]
let%expect_test "bounded work, coalescing, cache reuse, stable selection and explicit limits" =
  let c = controller "alpha\nbeta\nbeta\n界" in
  let t = Lines.create c in
  Lines.work t ~budget:1; assert (Lines.prepared_count t = 1);
  search t "bt"; assert (Lines.prepared_count t = 4);
  Lines.update t Next; assert (Option.equal Int.equal (Lines.selected t) (Some 3));
  Lines.update t Delete_word; drain t; assert (Option.equal Int.equal (Lines.selected t) (Some 3));
  Lines.update t (Paste "alpha"); Lines.work t ~budget:1;
  Lines.update t Delete_word; search t "界";
  assert (Option.equal Int.equal (Lines.selected t) (Some 4) && Lines.prepared_count t = 4);
  let t = Lines.create (controller ("ok\n" ^ String.make 4097 'a' ^ "\nlater")) in
  drain t; assert (Lines.truncated t && List.length (Lines.results t) = 1);
  let t = Lines.create (controller "") in drain t;
  assert (List.length (Lines.results t) = 1);
  [%expect {| |}]
let%expect_test "shared matching equivalence, Unicode query editing and mode refusal" =
  let texts = [ "alpha beta"; "alpha beta"; "界模型"; " scattered a___b___c "; "" ] in
  let c = controller (String.concat texts ~sep:"\n") in
  let t = Lines.create c in
  List.iter [ ""; "ab"; "alpha beta"; "界模型"; "abc"; "missing" ] ~f:(fun query ->
    while not (String.is_empty (Lines.query t)) do Lines.update t Delete_word done;
    search t query;
    let expected = Ches_palette.Fuzzy.rank ~policy:Loose_subsequence ~query
      (List.mapi texts ~f:(fun i text -> i + 1,
        [ { Ches_palette.Fuzzy.Field.tag = (); text; weight = 100 } ])) in
    assert (List.equal Int.equal (List.map (Lines.results t) ~f:(fun r -> r.line))
      (List.map expected ~f:(fun r -> r.item)));
    List.iter2_exn (Lines.results t) expected ~f:(fun actual expected ->
      assert (actual.score = expected.score);
      assert (List.equal Int.equal actual.positions (List.concat_map expected.positions ~f:snd))));
  while not (String.is_empty (Lines.query t)) do Lines.update t Delete_word done;
  Lines.update t (Paste "界\n模型\027");
  assert (String.equal (Lines.query t) "界 模型");
  Lines.update t Backspace; assert (String.equal (Lines.query t) "界 模");
  let c = command c (Enter_insert Before_cursor) in
  let t = Lines.create c in drain t;
  assert (Or_error.is_error (Lines.accept t ~current:(fun () -> c) ~release:ignore));
  assert (Lines.closed t && Editor.cursor (Controller.editor c) = 0);
  [%expect {| |}]
