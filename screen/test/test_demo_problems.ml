open! Core
open Ches_core
open Ches_screen
open Helpers
module Controller = Ches_app.Controller
module Feedback = Ches_error.Error

let%expect_test "demo startup is opt-in, bounded, valid for empty/Unicode files, and never edits" =
  List.iter [ ""; "one line"; "\t界🙂\nsecond\n\nlast" ] ~f:(fun text ->
    let original = Ui_state.controller (ui ~path:"demo.txt" text) in
    assert (List.is_empty (Feedback.problems (Controller.feedback original)));
    let controller = Ches_app.Demo_problems.install original in
    let problems = Feedback.problems (Controller.feedback controller) in
    assert (List.length problems = 8);
    assert (List.for_all problems ~f:(fun p -> not p.attention));
    assert (Text_buffer.equal (Editor.text (Controller.editor original))
      (Editor.text (Controller.editor controller)));
    assert (not (Editor.is_dirty (Controller.editor controller)));
    let twice = Ches_app.Demo_problems.install controller in
    assert (List.equal Feedback.Problem.equal problems (Feedback.problems (Controller.feedback twice)));
    List.iter problems ~f:(fun p ->
      let location = Option.value_exn p.location in
      let jumped = Controller.jump controller ~line:location.line ~column:location.column |> Or_error.ok_exn in
      assert (Editor.cursor_line (Controller.editor jumped) + 1 = location.line));
    let t = Ui_state.create controller |> fun t -> run ~width:80 ~height:16 t (keys " voG<CR>") in
    assert (not (Ui_state.problems_focused t ~width:80 ~height:16));
    assert (Editor.cursor_line (Controller.editor (Ui_state.controller t)) =
      Text_buffer.line_count (Editor.text (Controller.editor original)) - 1);
    let t = run ~width:80 ~height:16 t (keys " voei") in
    assert (Ui_state.problem_details t);
    assert (Text_buffer.equal (Editor.text (Controller.editor original))
      (Editor.text (Controller.editor (Ui_state.controller t)))));
  let unnamed = Controller.create (Editor.create ~cell_width:Cell_map.width Text_buffer.empty)
    |> Ches_app.Demo_problems.install in
  assert (List.is_empty (Feedback.problems (Controller.feedback unnamed)));
  print_endline "eight opt-in demo entries; all locations jump; empty and Unicode files stay unchanged";
  [%expect {| eight opt-in demo entries; all locations jump; empty and Unicode files stay unchanged |}]
;;

let%expect_test "demo namespace cannot resolve or acknowledge real failures" =
  let identity : Feedback.Identity.t = { source = "file"; kind = Save; resource = "demo.txt" } in
  let controller = Ui_state.controller (ui ~path:"demo.txt" "hello")
    |> fun c -> Controller.update_feedback c (Failed (identity, Error, "real failure"))
    |> Ches_app.Demo_problems.install in
  let f = Controller.feedback controller in
  assert (List.length (Feedback.problems f) = 9);
  assert (List.hd_exn (Feedback.problems f)).attention;
  assert (String.equal (Option.value_exn (Feedback.notification f)).text "real failure");
  let f = Feedback.apply f (Resolve identity) in
  assert (List.length (Feedback.problems f) = 8);
  assert (List.for_all (Feedback.problems f) ~f:(fun p ->
    String.is_prefix p.identity.source ~prefix:"demo/"));
  print_endline "demo and real file failures remain independent";
  [%expect {| demo and real file failures remain independent |}]
;;
