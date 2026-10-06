open! Core
open Ches_core
open Ches_screen
module Feedback = Ches_error.Error
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id

let width = 80
let height = 16

let id i : Feedback.Identity.t = { source = sprintf "checker%d" i; kind = Save; resource = "a" }

let create ?(report = Report_tile.demo) () =
  let t =
    Helpers.ui ~path:"a" "first\nsecond\nthird"
    |> fun t ->
    Ui_state.create ~report (Ui_state.controller t)
  in
  List.fold (List.range 0 4) ~init:t ~f:(fun t i ->
    Ui_state.update_feedback t ~width ~height
      (Report (id i, Warning, sprintf "finding %d" i, Some { line = 2; column = 1 })))
;;

let run ?(width = width) ?(height = height) t keys =
  Helpers.run ~width ~height t (Helpers.keys keys)
;;

let focused ?(width = width) ?(height = height) t =
  View_id.to_string (Ui_state.focused_view t ~width ~height)
;;

let problems t = Feedback.problems (Controller.feedback (Ui_state.controller t))
let editor t = Controller.editor (Ui_state.controller t)
let text t = Text_buffer.to_string (Editor.text (editor t))
let report t = Option.value_exn (Ui_state.report t)

let report_selected t =
  Option.value_exn
    (Report_tile.fit (report t) ~rows:4 ~width:40 |> Report_tile.selection).selected
;;

let problem_selected t =
  (Ui_state.problem_navigation t ~width ~height).selected
  |> Option.value_map ~default:"none" ~f:(fun (i : Feedback.Identity.t) -> i.source)
;;

let screen ?(width = width) ?(height = height) t =
  Frame.to_string (Frame.render t ~width ~height)
;;

let%expect_test "document, status, problems, and an error-free report coexist" =
  let t = create () |> fun t -> run t " vt vb vd" in
  let w = Ui_state.workspace t ~width ~height in
  print_s
    [%sexp
      (List.map
         (w.document :: (Option.to_list w.status @ w.minors))
         ~f:(fun (p : Workspace.Pane.t) -> p.id, p.rect)
       : (Workspace.Pane_id.t * Geometry.Rect.t) list)];
  [%expect
    {|
    ((Document ((x 0) (y 0) (width 51) (height 11)))
     (Status ((x 52) (y 0) (width 28) (height 11)))
     ((Minor problems) ((x 0) (y 11) (width 39) (height 5)))
     ((Minor demo-report) ((x 40) (y 11) (width 40) (height 5))))
    |}];
  (* The report is reached and driven by the same host as problems. *)
  let before = problems t in
  let t = run t " vDjj" in
  print_endline (focused t ^ " " ^ report_selected t);
  [%expect {| demo-report demo-report/03 |}];
  print_endline
    (String.concat ~sep:"\n" (List.drop (String.split_lines (screen t)) 10));
  [%expect
    {|
    ╰─────────────────────────────────────────────────╯ ╰──────────────────────────╯|
    ╭─ Problems (workspace): 4/4 ─────────╮ ╭─ Demo report* (static): [3/10] ──────╮|
    │ warning [checker0] a:2:1: finding 0 │ │   DEMO REPORT 1/10: static row 1 ( > │|
    │ warning [checker1] a:2:1: finding 1 │ │   DEMO REPORT 2/10: static row 2 ( > │|
    │ warning [checker2] a:2:1: finding 2 │ │ > DEMO REPORT 3/10: static row 3 ( > │|
    ╰─ +1 more | Space v e: all details ──╯ ╰─ 0 above, 7 below | j/k e yy Esc ────╯|
    cursor: none
    |}];
  (* Details open, scroll, and close through the shared escape precedence. *)
  let t = run t "Ge" in
  assert (Report_tile.details (report t));
  let t = run t "G" in
  assert (Report_tile.detail_top (report t) > 0);
  let t = run t "<Esc>" in
  assert ((not (Report_tile.details (report t))) && String.equal (focused t) "demo-report");
  (* Report actions, details, and capture notices never touch active problems. *)
  let t = run t "aq<CR><Esc>" in
  assert (List.equal Feedback.Problem.equal before (problems t));
  (* Workspace bindings move focus between minor views; editing still works after. *)
  let t = run t " vD vo" in
  print_endline (focused t ^ " " ^ problem_selected t);
  let t = run t "j vD" in
  print_endline (focused t ^ " " ^ problem_selected t ^ " " ^ report_selected t);
  let t = run t "<Tab>iX<Esc>" in
  print_endline (focused t ^ " " ^ text t);
  let t = run t "u" in
  assert (String.equal (text t) "first\nsecond\nthird");
  [%expect
    {|
    problems checker0
    demo-report checker1 demo-report/10
    document Xfirst
    second
    third
    |}]
;;

let%expect_test "showing, hiding, or using one view never changes the other's state" =
  let t = create () |> fun t -> run t " vb vf vojj<Esc> vd vDjjje" in
  let problems_tile t = Ui_state.problems_tile t in
  let snapshot t =
    ( problem_selected t
    , Problems_tile.current_document (problems_tile t)
    , report_selected t
    , Report_tile.details (report t) )
  in
  let expected = snapshot t in
  print_s [%sexp (expected : string * bool * string * bool)];
  [%expect {| (checker2 true demo-report/04 true) |}];
  (* Toggling and refocusing problems leaves the report's selection alone, and the
     reverse; only leaving a view closes its own details. *)
  let t = run t "<Tab> vb vb vd vd" in
  print_s [%sexp (snapshot t : string * bool * string * bool)];
  [%expect {| (checker2 true demo-report/04 false) |}];
  (* Feedback updates while the report is focused or hidden reconcile problems only. *)
  let t = run t " vD" in
  let t = Ui_state.update_feedback t ~width ~height (Resolve (id 2)) in
  print_endline (focused t ^ " " ^ problem_selected t ^ " " ^ report_selected t);
  let t = run t " vd" in
  let t = Ui_state.update_feedback t ~width ~height (Resolve (id 3)) in
  let t = Ui_state.update_feedback t ~width ~height (Report (id 9, Error, "new", None)) in
  let t = run t " vd" in
  print_endline (focused t ^ " " ^ problem_selected t ^ " " ^ report_selected t);
  [%expect
    {|
    demo-report checker3 demo-report/04
    document checker1 demo-report/04
    |}];
  (* Acknowledging from problems leaves the report alone and resolves nothing. *)
  let t = run t " voa" in
  print_s
    [%sexp
      (List.map (problems t) ~f:(fun p -> p.identity.source, p.attention)
       : (string * bool) list), (report_selected t : string)];
  [%expect {| (((checker0 true) (checker1 false) (checker9 true)) demo-report/04) |}]
;;

let%expect_test "paste, cursor, zen, and compact ownership are shared rules" =
  let t = create () |> fun t -> run t " vb vd vD" in
  let cursor ?(width = width) ?(height = height) t =
    Option.is_some (Frame.render t ~width ~height).cursor
  in
  assert (not (cursor t));
  (* A paste begun in the report is rejected even after a resize drops the report and
     returns focus to the document mid-paste. Keys during a paste are text, so Tab
     cannot move focus. *)
  let t = Helpers.run ~width ~height t (Ui_state.Input.Paste_start :: Helpers.keys "ij<Tab>") in
  let t = Helpers.run ~width:30 ~height t [ Ui_state.Input.Resize ] in
  print_endline (focused ~width:30 t);
  let t = Helpers.run ~width:30 ~height t [ Ui_state.Input.Paste_end ] in
  print_endline (focused ~width:30 t ^ " " ^ text t);
  print_endline (Option.value (Ui_state.capture_notice t) ~default:"-");
  [%expect
    {|
    document
    document first
    second
    third
    Demo report: read-only; paste ignored
    |}];
  (* And a paste begun in the document stays literal text, even mid-capture keys. *)
  let t = run t " vD" in
  let t = run t "<Tab>i" in
  let t = Helpers.run ~width ~height t (Helpers.paste " vDj") in
  print_endline (focused t ^ " " ^ text t);
  [%expect {|
    document  vDjfirst
    second
    third
    |}];
  let t = run t "<Esc>u vD" in
  assert (String.equal (text t) "first\nsecond\nthird" && not (cursor t));
  (* Zen and a narrow screen return focus to the document, keeping requests. *)
  let t = run t " vz" in
  print_endline (focused t);
  assert (cursor t && Ui_state.report_visible t);
  let t = run t " vz vD" in
  let t = Helpers.run ~width:30 ~height t [ Ui_state.Input.Resize ] in
  print_s
    [%sexp
      (focused ~width:30 t : string)
    , (List.map (Ui_state.workspace t ~width:30 ~height).minors ~f:(fun p -> p.id)
       : Workspace.Pane_id.t list)];
  assert (cursor ~width:30 t && Ui_state.report_visible t);
  let t = Helpers.run ~width ~height t [ Ui_state.Input.Resize ] in
  print_endline (focused t);
  [%expect
    {|
    document
    (document ((Minor problems)))
    document
    |}];
  (* Without --demo-report the bindings only give notices. *)
  let t = run (Helpers.ui "x") " vd vD" in
  assert (List.is_empty (Ui_state.workspace t ~width ~height).minors);
  print_endline (Option.value (Ui_state.message t) ~default:{ kind = Info; text = "-" }).text;
  [%expect {| Demo report unavailable; launch with --demo-report |}]
;;

let%expect_test "two minor views stay bounded and disjoint in every allocation" =
  List.iter [ ""; " vt"; " vt vph"; " vt vpk"; " vt vpj" ] ~f:(fun position ->
    let t = create () |> fun t -> run t (position ^ " vb vd vDGe") in
    List.iter [ t; run t " vo" ] ~f:(fun t ->
      List.iter (List.range 0 90 ~stride:3) ~f:(fun width ->
        List.iter (List.range 0 18) ~f:(fun height ->
          let w = Ui_state.workspace t ~width ~height in
          let panes = w.document :: (Option.to_list w.status @ w.minors) in
          List.iter panes ~f:(fun a ->
            let r = a.rect in
            assert (r.x >= 0 && r.y >= 0 && r.x + r.width <= width && r.y + r.height <= height);
            List.iter panes ~f:(fun b ->
              if not (Workspace.Pane_id.equal a.id b.id)
              then (
                let a = a.rect
                and b = b.rect in
                assert (
                  a.x + a.width <= b.x
                  || b.x + b.width <= a.x
                  || a.y + a.height <= b.y
                  || b.y + b.height <= a.y))));
          List.iter w.minors ~f:(fun p -> assert (p.rect.width >= Workspace.min_minor_width));
          let frame = Frame.render t ~width ~height in
          assert (List.length frame.rows = height);
          List.iter frame.rows ~f:(fun row ->
            assert (Span.total_width row = width);
            List.iter row ~f:(fun span ->
              assert (Cell_map.total_width (Cell_map.glyphs span.Span.text) = span.width)));
          let document_owns =
            Option.exists (Ui_state.cursor_owner t ~width ~height)
              ~f:(View_id.equal Ui_state.document_id)
          in
          if not document_owns
          then
            assert (
              [%equal: (int * int) option]
                (Option.map frame.cursor ~f:(fun c -> c.x, c.y))
                (Ui_state.text_cursor t ~width ~height))))));
  print_endline "panes bounded and disjoint; one cursor owner draws a cursor";
  [%expect {| panes bounded and disjoint; one cursor owner draws a cursor |}]
;;

let%expect_test "status and minor views share the framed shell at a laptop size" =
  let width = 110
  and height = 30 in
  let t = create () |> fun t -> run ~width ~height t " vt vb vd vDj" in
  print_endline (screen ~width ~height t);
  (* Only the focused view's frame is accented. *)
  let frame = Frame.render t ~width ~height in
  List.nth_exn frame.rows 20
  |> List.filter_map ~f:(fun (s : Span.t) ->
    match s.style with
    | Border | Border_focused -> Some (Style.to_string_hum s.style)
    | _ -> None)
  |> String.concat ~sep:" "
  |> print_endline;
  [%expect
    {|
    ╭─ a ───────────────────────────────────────────────────────────────────────────╮ ╭─ Status ─────────────────╮|
    │  first                                                                        │ │ NORMAL                   │|
    │  second                                                                       │ │ a                        │|
    │  third                                                                        │ │ 1:1                      │|
    │                                                                               │ │ [4 problems] finding 0   │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    │                                                                               │ │                          │|
    ╰───────────────────────────────────────────────────────────────────────────────╯ ╰──────────────────────────╯|
    ╭─ Problems (workspace): 4/4 ────────────────────────╮ ╭─ Demo report* (static): [2/10] ─────────────────────╮|
    │ warning [checker0] a:2:1: finding 0                │ │   DEMO REPORT 1/10: static row 1 (界🙂 é)           │|
    │ warning [checker1] a:2:1: finding 1                │ │ > DEMO REPORT 2/10: static row 2 (界🙂 é)           │|
    │ warning [checker2] a:2:1: finding 2                │ │   DEMO REPORT 3/10: static row 3 (界🙂 é)           │|
    │ warning [checker3] a:2:1: finding 3                │ │   DEMO REPORT 4/10: static row 4 (界🙂 é)           │|
    │                                                    │ │   DEMO REPORT 5/10: static row 5 (界🙂 é)           │|
    │                                                    │ │   DEMO REPORT 6/10: static row 6 (界🙂 é)           │|
    │                                                    │ │   DEMO REPORT 7/10: static row 7 (界🙂 é)           │|
    │                                                    │ │   DEMO REPORT 8/10: static row 8 (界🙂 é)           │|
    ╰─ Space v o: focus | Space v e: details ────────────╯ ╰─ 0 above, 2 below | j/k e yy Esc ───────────────────╯|
    cursor: none
    Border Border Border_focused Border_focused
    |}];
  (* The adapter's viewport is the shell's content area, and returns with the
     allocation after the terminal shrinks and grows. *)
  let layout ~width ~height =
    Option.map (Ui_state.minor_layout t ~width ~height Report_tile.id) ~f:(fun l ->
      l.content)
  in
  let before = layout ~width ~height in
  print_s [%sexp (before : Geometry.Rect.t option), (layout ~width:20 ~height:8 : Geometry.Rect.t option)];
  let t = Helpers.run ~width:20 ~height:8 t [ Ui_state.Input.Resize ] in
  let t = Helpers.run ~width ~height t [ Ui_state.Input.Resize ] in
  assert ([%equal: Geometry.Rect.t option] before (layout ~width ~height));
  print_endline (focused ~width ~height t);
  [%expect {|
    ((((x 57) (y 21) (width 51) (height 8))) ())
    document
    |}]
;;

let%expect_test "gaps stay backdrop; the tiles' borders separate them" =
  let width = 60
  and height = 16 in
  let t = create () |> fun t -> run ~width ~height t " vt vb vd" in
  let gaps = (Ui_state.workspace t ~width ~height).gaps in
  print_s [%sexp (gaps : Geometry.Rect.t list)];
  print_endline (screen ~width ~height t);
  let style_at (frame : Frame.t) ~x ~y =
    List.nth_exn frame.rows y
    |> List.folding_map ~init:0 ~f:(fun left (s : Span.t) -> left + s.width, (left, s))
    |> List.find_map_exn ~f:(fun (left, (s : Span.t)) ->
      Option.some_if (x >= left && x < left + s.width) (s.text, s.style))
  in
  let frame = Frame.render t ~width ~height in
  List.iter gaps ~f:(fun (r : Geometry.Rect.t) ->
    for y = r.y to r.y + r.height - 1 do
      let text, style = style_at frame ~x:r.x ~y in
      assert (Style.equal style Backdrop && String.is_prefix text ~prefix:" ")
    done);
  [%expect {|
    (((x 31) (y 0) (width 1) (height 11)) ((x 29) (y 11) (width 1) (height 5)))
    ╭─ a ─────────────────────────╮ ╭─ Status ─────────────────╮|
    │  first                      │ │ NORMAL                   │|
    │  second                     │ │ a                        │|
    │  third                      │ │ 1:1                      │|
    │                             │ │ [4 problems] finding 0   │|
    │                             │ │                          │|
    │                             │ │                          │|
    │                             │ │                          │|
    │                             │ │                          │|
    │                             │ │                          │|
    ╰─────────────────────────────╯ ╰──────────────────────────╯|
    ╭─ Problems (workspace): 4> ╮ ╭─ Demo report (static): 10> ╮|
    │ warning [checker0] a:2:1> │ │ DEMO REPORT 1/10: static > │|
    │ warning [checker1] a:2:1> │ │ DEMO REPORT 2/10: static > │|
    │ warning [checker2] a:2:1> │ │ DEMO REPORT 3/10: static > │|
    ╰─ +1 more | Space v e: al> ╯ ╰─ Space v D: focus ─────────╯|
    cursor: 3,1 Block
    |}]
;;
