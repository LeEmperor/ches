open! Core
open Ches_core
open Ches_screen
open Helpers
module Feedback = Ches_error.Error
module Controller = Ches_app.Controller

let identity ?(source = "file") resource : Feedback.Identity.t =
  { source; resource; kind = Save }
;;

let rows feedback ?(current_document = false) ?(path = Some "a") ?(width = 100) ?(height = 4) () =
  Problems.render feedback ~current_document ~path
    ~rect:{ Geometry.Rect.x = 0; y = 0; width; height }
;;

let show rows =
  List.iter rows ~f:(fun spans ->
    print_endline (String.rstrip (String.concat (List.map spans ~f:(fun s -> s.Span.text)))))
;;

let%expect_test "empty, multiple sources, location, acknowledgement, updates and resolution" =
  show (rows Feedback.empty ());
  let a = identity "a" and b = identity ~source:"checker" "a" in
  let f = Feedback.apply Feedback.empty (Failed (a, Error, "cannot save")) in
  let f = Feedback.apply f (Report (b, Warning, "finding", Some { line = 3; column = 7 })) in
  let f = Feedback.apply f Acknowledge in
  assert (not (List.hd_exn (Feedback.problems f)).attention);
  show (rows f ());
  let f = Feedback.apply f (Failed (a, Error, "retry failed")) in
  assert (List.length (Feedback.problems f) = 2);
  assert (List.hd_exn (Feedback.problems f)).attention;
  show (rows f ());
  let f = Feedback.apply f (Resolve a) in
  show (rows f ());
  let f = Feedback.apply f (Resolve b) in
  show (rows f ());
  [%expect {|
    Problems (workspace): 0/0 | Space v e: details
    No active problems


    Problems (workspace): 2/2 | Space v e: details
    error [file] a: cannot save
    warning [checker] a:3:7: finding

    Problems (workspace): 2/2 | Space v e: details
    error [file] a: retry failed
    warning [checker] a:3:7: finding

    Problems (workspace): 1/1 | Space v e: details
    warning [checker] a:3:7: finding


    Problems (workspace): 0/0 | Space v e: details
    No active problems
    |}]
;;

let fixture () =
  List.fold (List.range 0 8) ~init:Feedback.empty ~f:(fun f i ->
    Feedback.apply f (Failed (identity (if i = 0 then "a" else sprintf "b%d" i), Error,
      sprintf "problem %d" i)))
;;

let%expect_test "filtering and bounded overflow leave every detail reachable" =
  let f = fixture () in
  show (rows f ());
  show (rows f ~current_document:true ());
  show (rows f ~current_document:true ~path:None ~height:2 ());
  assert (List.length (Feedback.problems f) = 8);
  ignore (List.fold (List.range 0 9) ~init:f ~f:(fun f i ->
    let f = Feedback.apply f Inspect_next in
    assert (String.equal (Option.value_exn (Feedback.notification f)).text
      (sprintf "problem %d" (i % 8)));
    f) : Feedback.t);
  [%expect {|
    Problems (workspace): 8/8 | Space v e: details
    error [file] a: problem 0
    error [file] b1: problem 1
    +6 more | Space v e: all details
    Problems (document): 1/8 | Space v e: details
    error [file] a: problem 0


    Problems (document): 0/8 | Space v e: details
    No active problems
    |}]
;;

let%expect_test "coexistence, requested visibility, zen, filtering and editor ownership" =
  let editor = Editor.create ~path:"a" ~cell_width:Cell_map.width
    (Text_buffer.of_string "hello\nworld"
      |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
      |> Result.ok_or_failwith) in
  let controller = List.fold (Feedback.problems (fixture ()))
    ~init:(Controller.create editor) ~f:(fun c p ->
      Controller.update_feedback c (Failed (p.identity, p.severity, p.text))) in
  let t = Ui_state.create controller |> fun t -> run ~width:80 ~height:16 t (keys " vt vb") in
  let w = Ui_state.workspace t ~width:80 ~height:16 in
  assert (Option.is_some w.status && Option.is_some w.problems);
  assert (Workspace.Pane.focusable (Option.value_exn w.problems));
  let original = Controller.feedback (Ui_state.controller t) in
  let t = run ~width:80 ~height:16 t (keys " vf vb vb vz") in
  assert (Ui_state.problems_visible t && Ui_state.problems_current_document t);
  assert (Option.is_none (Ui_state.workspace t ~width:80 ~height:16).problems);
  let t = run ~width:80 ~height:16 t (keys " vz") in
  assert (Option.is_some (Ui_state.workspace t ~width:80 ~height:16).problems);
  assert (List.equal Feedback.Problem.equal (Feedback.problems original)
    (Feedback.problems (Controller.feedback (Ui_state.controller t))));
  assert (Option.is_none (Ui_state.workspace t ~width:15 ~height:4).problems);
  assert (Ui_state.problems_visible t);
  let frame = Frame.render t ~width:80 ~height:16 in
  assert (String.is_substring (Frame.to_string frame) ~substring:"Problems (document): 1/8");
  assert (String.is_substring (Frame.to_string frame) ~substring:"8 problems");
  let t = run ~width:80 ~height:16 t (keys "iX<Esc>u") in
  assert (String.equal (Text_buffer.to_string (Editor.text (Controller.editor (Ui_state.controller t))))
    "hello\nworld");
  print_endline "state retained; preview/status agree; input and undo remain in editor";
  [%expect {| state retained; preview/status agree; input and undo remain in editor |}]
;;

let%expect_test "all allocations, status positions, Unicode and control text stay bounded" =
  let controller = Controller.create (Editor.create ~path:"a" ~cell_width:Cell_map.width Text_buffer.empty)
    |> fun c -> Controller.update_feedback c
      (Failed (identity "a", Error, "界🙂é\t\027\nlong problem")) in
  List.iter [ ""; " vph"; " vpl"; " vpk"; " vpj" ] ~f:(fun position ->
    let t = run ~width:80 ~height:16 (Ui_state.create controller) (keys (" vb" ^ position)) in
    List.iter (List.range 0 45) ~f:(fun width ->
      List.iter (List.range 0 18) ~f:(fun height ->
        let w = Ui_state.workspace t ~width ~height in
        let panes = w.document :: List.filter_opt [ w.status; w.problems ] in
        List.iter panes ~f:(fun p ->
          let r = p.Workspace.Pane.rect in
          assert (r.x >= 0 && r.y >= 0 && r.x + r.width <= width && r.y + r.height <= height));
        List.iter panes ~f:(fun a -> List.iter panes ~f:(fun b ->
          if not (Workspace.Pane_id.equal a.id b.id) then (
            let a = a.rect and b = b.rect in
            assert (a.x + a.width <= b.x || b.x + b.width <= a.x
              || a.y + a.height <= b.y || b.y + b.height <= a.y))));
        let frame = Frame.render t ~width ~height in
        assert (List.length frame.rows = height);
        List.iter frame.rows ~f:(fun row ->
          assert (Span.total_width row = width);
          List.iter row ~f:(fun span ->
            assert (Cell_map.total_width (Cell_map.glyphs span.Span.text) = span.width);
            assert (not (String.exists span.Span.text ~f:(fun c -> Char.to_int c < 32 || Char.to_int c = 127)))));
        Option.iter frame.cursor ~f:(fun cursor ->
          assert (cursor.x < w.document.rect.x + w.document.rect.width);
          assert (cursor.y < w.document.rect.y + w.document.rect.height)))));
  print_endline "all bounds hold";
  [%expect {| all bounds hold |}]
;;
