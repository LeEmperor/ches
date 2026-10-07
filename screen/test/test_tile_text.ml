open! Core
open Ches_core
open Ches_screen
module Feedback = Ches_error.Error
module Controller = Ches_app.Controller
module View_id = Ches_tile.View_id

let width = 80
let height = 16

let id i : Feedback.Identity.t = { source = sprintf "checker%d" i; kind = Save; resource = "a" }

let create () =
  let t = Helpers.ui ~path:"a" "first\nsecond\nthird" in
  let t = Ui_state.create ~report:Report_tile.demo (Ui_state.controller t) in
  List.fold (List.range 0 3) ~init:t ~f:(fun t i ->
    Ui_state.update_feedback t ~width ~height
      (Report (id i, Warning, sprintf "finding %d" i, Some { line = 2; column = 1 })))
;;

let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let editor t = Controller.editor (Ui_state.controller t)
let text t = Text_buffer.to_string (Editor.text (editor t))
let problems t = Feedback.problems (Controller.feedback (Ui_state.controller t))
let focused t = View_id.to_string (Ui_state.focused_view t ~width ~height)
let notice t = Option.value (Ui_state.capture_notice t) ~default:"-"

(* The band rows of the screen and the cursor line. *)
let band t =
  let lines = String.split_lines (Frame.to_string (Frame.render t ~width ~height)) in
  print_endline (String.concat ~sep:"\n" (List.drop lines 11))
;;

(* What the frontend would put on the system clipboard, and the editor's register. *)
let copied t =
  let t, clipboard = Ui_state.take_clipboard t in
  print_s
    [%sexp
      (clipboard : string option)
    , (Editor.unnamed_register (editor t) : Register.t option)];
  t
;;

(* The text drawn in the selection style, row by row. *)
let highlighted t =
  let selection = Style.document ~overlay:Selection () in
  List.iter (Frame.render t ~width ~height).rows ~f:(fun row ->
    match List.filter row ~f:(fun (s : Span.t) -> Style.equal s.style selection) with
    | [] -> ()
    | spans -> print_s [%sexp (String.concat (List.map spans ~f:(fun s -> s.text)) : string)])
;;

let%expect_test "report details: the text cursor reaches rows beyond the viewport" =
  let t = create () |> fun t -> run t " vd vDGe" in
  band t;
  [%expect
    {|
    ╭─ Demo report* details (static): [10/10] ─────────────────────────────────────╮|
    │ DEMO REPORT 10/10: static row 10 (界🙂 é): Static report item 10. This fixtu │|
    │ re has no source, file, or problem identity; selecting, scrolling, copying,  │|
    │ or hiding it changes nothing else. Long detail sentence 1: scroll with j/k o │|
    ╰─ Details 1-3/11 | hjkl w b v V yy; e/Esc back ───────────────────────────────╯|
    cursor: 2,12 Block
    |}];
  (* The terminal cursor follows the text cursor down past the visible rows. *)
  let t = run t "jjjllll" in
  band t;
  [%expect
    {|
    ╭─ Demo report* details (static): [10/10] ─────────────────────────────────────╮|
    │ re has no source, file, or problem identity; selecting, scrolling, copying,  │|
    │ or hiding it changes nothing else. Long detail sentence 1: scroll with j/k o │|
    │ r Ctrl-d/u. Long detail sentence 2: scroll with j/k or Ctrl-d/u. Long detail │|
    ╰─ Details 2-4/11 | hjkl w b v V yy; e/Esc back ───────────────────────────────╯|
    cursor: 6,14 Block
    |}];
  let t = run t "G" in
  print_s [%sexp (Report_tile.detail_top (Option.value_exn (Ui_state.report t)) : int)];
  [%expect {| 8 |}];
  (* Escape closes details: back to the list, which has no text cursor. *)
  let t = run t "<Esc>" in
  print_s
    [%sexp
      (focused t : string)
    , (Ui_state.minor_cursor t ~width ~height : (int * int * Ches_tile.Cursor.Shape.t) option)
    , (Report_tile.details (Option.value_exn (Ui_state.report t)) : bool)];
  [%expect {| (demo-report () false) |}]
;;

let%expect_test "Visual selection copies canonical text to the register and clipboard" =
  let t = create () |> fun t -> run t " vd vDGe" in
  let revision = Editor.revision (editor t) in
  (* From "fixture", cut by the wrap, to the blank after it: the highlight covers both
     rows; the copy is the source bytes, without the wrap, padding, or border. *)
  let t = run t "jbvwh" in
  highlighted t;
  [%expect
    {|
    fixtu
    "re "
    |}];
  let t = run t "y" |> copied in
  [%expect {| (("fixture ") ((Text (text "fixture ") (kind Characterwise)))) |}];
  print_s
    [%sexp
      (notice t : string)
    , (Ches_tile.Text_view.visual
         (Option.value_exn (Report_tile.text_view (Option.value_exn (Ui_state.report t))))
       : Ches_tile.Text_view.Kind.t option)];
  [%expect {| ("Copied 8 characters" ()) |}];
  (* A linewise copy is the whole logical line, not the rows it wraps to. *)
  let t, clipboard = Ui_state.take_clipboard (run t "Vy") in
  let clipboard = Option.value_exn clipboard in
  print_s
    [%sexp
      (notice t : string)
    , (String.count clipboard ~f:(Char.equal '\n') : int)
    , (String.equal
         clipboard
         (Report_tile.demo
          |> List.last_exn
          |> fun (item : Report_tile.Item.t) -> sprintf "%s: %s\n" item.title item.body)
       : bool)];
  [%expect {| ("Copied 1 line" 1 true) |}];
  (* Copying ran no editor command: same text, revision, and dirty state. *)
  assert (Editor.revision (editor t) = revision && not (Editor.is_dirty (editor t)));
  assert (String.equal (text t) "first\nsecond\nthird");
  (* Escape ends Visual, closes details, then returns; [p] in the editor pastes what was
     copied, and undo removes it. *)
  let t = run t "v<Esc>" in
  print_s [%sexp (focused t : string), (Report_tile.details (Option.value_exn (Ui_state.report t)) : bool)];
  let t = run t "<Esc>" in
  print_s [%sexp (focused t : string), (Report_tile.details (Option.value_exn (Ui_state.report t)) : bool)];
  let t = run t "<Esc>" in
  print_endline (focused t);
  let t = run t "p" in
  print_endline (List.nth_exn (String.split_lines (text t)) 1 |> Fn.flip String.prefix 29);
  let t = run t "u" in
  print_endline (text t);
  [%expect
    {|
    (demo-report true)
    (demo-report false)
    document
    DEMO REPORT 10/10: static row
    first
    second
    third
    |}]
;;

let%expect_test "problems: copying, selecting, rejection, and updates keep the lifecycle" =
  (* [e] inspects (its existing meaning); nothing after it changes any problem. *)
  let t = create () |> fun t -> run t " voe<Esc>" in
  let before = problems t in
  let t = run t "yy" |> copied in
  [%expect
    {|
    (("warning [checker0] a:2:1: finding 0\n")
     ((Text (text "warning [checker0] a:2:1: finding 0\n") (kind Linewise))))
    |}];
  (* Details: from the source to the end of the line, characterwise. *)
  let t = run t "ewv$y" |> copied in
  [%expect
    {|
    (("[checker0] a:2:1: finding 0")
     ((Text (text "[checker0] a:2:1: finding 0") (kind Characterwise))))
    |}];
  (* Edits are rejected in details and in the list; the document is untouched. *)
  let t = run t "x" in
  print_endline (notice t);
  let t = run t "<Esc>p" in
  print_endline (notice t);
  [%expect
    {|
    Problems: read-only; edits unavailable
    Problems: read-only; edits unavailable
    |}];
  assert (String.equal (text t) "first\nsecond\nthird" && not (Editor.is_dirty (editor t)));
  assert (List.equal Feedback.Problem.equal before (problems t));
  (* The source changes the selected problem's text mid-selection: the selection ends
     with a notice, and [y] can no longer copy what was selected. *)
  let t = run t "ewv" in
  let t =
    Ui_state.update_feedback t ~width ~height
      (Report (id 0, Warning, "finding 0, revised", Some { line = 2; column = 1 }))
  in
  print_endline (notice t);
  let t = run t "y<Esc>" |> copied in
  print_s
    [%sexp
      (Option.map (Problems_tile.text_view (Ui_state.problems_tile t)) ~f:Ches_tile.Text_view.text
       : string option)];
  [%expect
    {|
    Details updated; selection cleared
    (() ((Text (text "[checker0] a:2:1: finding 0") (kind Characterwise))))
    ("warning [checker0] a:2:1: finding 0, revised")
    |}];
  (* Tab returns to the document, which owns the cursor again; editing works. *)
  let t = run t "<Tab>" in
  print_s
    [%sexp
      (focused t : string)
    , (Ui_state.problem_details t : bool)
    , (Ui_state.cursor_owner t ~width ~height : View_id.t option)];
  let t = run t "iX<Esc>u" in
  assert (String.equal (text t) "first\nsecond\nthird");
  [%expect {| (document false (document)) |}]
;;
