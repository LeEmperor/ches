open! Core
open Ches_screen
open Ches_core

let%expect_test "the smear is opt-in, advances, and settles" =
  let animation = Animation.create ~enabled:false in
  let animation = Animation.retarget animation ~from:(Some (1, 1)) ~to_:(Some (8, 1)) in
  print_s [%sexp (Animation.active animation : bool)];
  let animation = Animation.set_enabled animation true in
  let animation = Animation.retarget animation ~from:(Some (1, 1)) ~to_:(Some (8, 1)) in
  print_s [%sexp (Animation.active animation : bool)];
  let animation = Animation.tick animation ~dt:0.017 in
  print_s [%sexp (Animation.cells animation ~width:20 ~height:5 : (int * int) list)];
  let animation = List.fold (List.init 100 ~f:Fn.id) ~init:animation ~f:(fun animation _ -> Animation.tick animation ~dt:0.017) in
  print_s [%sexp (Animation.active animation : bool)];
  [%expect
    {|
    false
    true
    ((1 1))
    false
    |}]
;;

let%expect_test "Space v s toggles the cursor effect without touching the editor" =
  let text =
    Text_buffer.of_string "hello"
    |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
    |> Result.ok_or_failwith
  in
  let controller = Ches_app.Controller.create (Ches_core.Editor.create ~path:"f" text) in
  let ui = Ui_state.create controller in
  let ui, _ =
    Ui_state.apply_all
      ui
      ~width:30
      ~height:5
      [ Ui_state.Input.Key (Ches_input.Key.char ' ')
      ; Ui_state.Input.Key (Ches_input.Key.char 'v')
      ; Ui_state.Input.Key (Ches_input.Key.char 's')
      ]
  in
  print_s [%sexp (Animation.enabled (Ui_state.animation ui) : bool)];
  print_s [%sexp (Ui_state.message ui : Ui_state.Message.t option)];
  [%expect
    {|
    true
    (((kind Info) (text "Smear cursor enabled")))
    |}]
;;
