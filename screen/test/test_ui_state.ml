open! Core
open Ches_core
open Ches_screen
open Helpers

let text t =
  Text_buffer.to_string
    (Editor.text (Ches_app.Controller.editor (Ui_state.controller t)))
;;

let message t = print_s [%sexp (Ui_state.message t : Ui_state.Message.t option)]

let%expect_test "message slot: notice, else editor message when a command ran, else \
                 unchanged"
  =
  let t = ui "abc" in
  (* An unbound continuation sets a notice. *)
  let t = run t (keys " z") in
  message t;
  [%expect {| (((kind Warning) (text "Space z is not bound"))) |}];
  (* Ignored keys and the first key of a sequence leave the slot alone. *)
  let t = run t (keys "Z ") in
  message t;
  [%expect {| (((kind Warning) (text "Space z is not bound"))) |}];
  (* A command with no message of its own clears it. *)
  let t = run t (keys "<Esc>l") in
  message t;
  [%expect {| () |}];
  (* Editor feedback appears, info or error. *)
  let t = run t (keys "u") in
  message t;
  [%expect {| (((kind Info) (text "Already at oldest change"))) |}];
  let t = run (ui ~path:"/nonexistent-dir/f.txt" "abc") (keys " w") in
  message t;
  [%expect
    {|
    (((kind Error)
      (text "Failed to write /nonexistent-dir/f.txt: No such file or directory")))
    |}]
;;

let%expect_test "Ctrl-c hints at Space q, in either mode, and never exits" =
  let t = run (ui "abc") (keys "<C-c>") in
  message t;
  show ~width:50 ~height:3 t;
  [%expect
    {|
    (((kind Warning) (text "To quit, use Space q in Normal mode")))
      1 abc                                           |
                                                      |
     NORMAL  f.txt To quit, use Space q in Norma> 1:1 |
    cursor: 4,0 Block
    |}];
  let t = run t (keys "ix<C-c>") in
  print_s [%sexp (text t : string)];
  message t;
  [%expect
    {|
    xabc
    (((kind Warning) (text "To quit, use Space q in Normal mode")))
    |}]
;;

let%expect_test "a bracketed paste is one literal insertion, even of Normal-mode keys"
  =
  let t = run (ui "") (keys "i" @ paste " q<Tab>jk<Esc>u" @ keys "<Esc>") in
  print_s [%sexp (text t : string)];
  [%expect {| " q\tjku" |}];
  (* One undo removes the whole paste: it was one insertion inside one transaction. *)
  let t = run t (keys "u") in
  print_s [%sexp (text t : string)];
  [%expect {| "" |}];
  (* In Normal mode a paste is ignored, with a notice, and runs nothing. *)
  let t = run (ui "abc") (paste " Qx") in
  print_s [%sexp (text t : string)];
  message t;
  [%expect
    {|
    abc
    (((kind Warning) (text "Paste ignored in Normal mode")))
    |}];
  print_s [%sexp (Ui_state.pasting t : bool)];
  [%expect {| false |}]
;;

let%expect_test "quitting: refused while dirty, forced, and clean" =
  let t = run (ui "abc") (keys "x q") in
  message t;
  [%expect {| (((kind Error) (text "Unsaved changes: save them or force quit"))) |}];
  let (_ : Ui_state.t) = run t (keys " Q") in
  [%expect {| EXIT |}];
  (* Inputs after the exit are not applied. *)
  let t, status = Ui_state.apply_all (ui "abc") ~width:40 ~height:8 (keys " qx") in
  print_s [%message (status : Ches_app.Controller.Status.t) (text t : string)];
  [%expect {| ((status Exit) ("text t" abc)) |}];
  (* Nor are later batches: a save typed right after a forced quit does nothing. *)
  let t = run (ui ~path:"/nonexistent-dir/f.txt" "abc") (keys "x Q") in
  let t = run t (keys " w") in
  print_s
    [%message
      (Ui_state.exited t : bool) (Ui_state.message t : Ui_state.Message.t option)];
  [%expect
    {|
    EXIT
    EXIT
    (("Ui_state.exited t" true) ("Ui_state.message t" ()))
    |}]
;;

let%expect_test "a burst of keys in one batch equals the keys one at a time" =
  let inputs = keys "ihello<CR>world<Esc>kx" @ paste "!" @ keys "u<C-r>" in
  let batch, _ = Ui_state.apply_all (ui "") ~width:30 ~height:5 inputs in
  let one_by_one =
    List.fold inputs ~init:(ui "") ~f:(fun t input ->
      fst (Ui_state.apply t ~width:30 ~height:5 input))
  in
  print_s [%sexp (text batch : string), (text one_by_one : string)];
  [%expect {|
    ( "hell\
     \nworld"  "hell\
              \nworld")
    |}]
;;

let%expect_test "after a resize the cursor stays visible, and the next input starts \
                 from what was on screen"
  =
  let lines = String.concat (List.init 40 ~f:(fun i -> sprintf "%d\n" (i + 1))) in
  let t = run ~width:30 ~height:30 (ui lines) (keys (String.make 25 'j')) in
  print_s [%sexp (Ui_state.scroll t : Scroll.t)];
  [%expect {| ((top 0) (left 0)) |}];
  (* Shrink: the render fits the scroll to the new size. *)
  print_s [%sexp (Ui_state.fitted_scroll t ~width:30 ~height:8 : Scroll.t)];
  show_cursor ~width:30 ~height:8 t;
  [%expect {|
    ((top 21) (left 0))
    cursor: 5,5 Block
    |}];
  (* One line up from there keeps the view where it was. *)
  let t = run ~width:30 ~height:8 t (keys "k") in
  print_s [%sexp (Ui_state.scroll t : Scroll.t)];
  [%expect {| ((top 21) (left 0)) |}]
;;
