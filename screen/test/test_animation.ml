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
    ((2 1))
    false
    |}]
;;

let%expect_test "head and tail follow the direction of travel" =
  let after_one_frame from to_ =
    Animation.create ~enabled:true
    |> Animation.retarget ~from:(Some from) ~to_:(Some to_)
    |> Animation.tick ~dt:0.017
    |> Animation.cells ~width:20 ~height:20
  in
  print_s [%sexp (after_one_frame (1, 5) (8, 5) : (int * int) list)];
  print_s [%sexp (after_one_frame (8, 5) (1, 5) : (int * int) list)];
  print_s [%sexp (after_one_frame (5, 1) (5, 8) : (int * int) list)];
  print_s [%sexp (after_one_frame (5, 8) (5, 1) : (int * int) list)];
  [%expect
    {|
    ((2 5))
    ((7 5))
    ((5 2))
    ((5 7))
    |}]
;;

let%expect_test "bad clock intervals do not distort the animation" =
  let animation =
    Animation.create ~enabled:true
    |> Animation.retarget ~from:(Some (1, 1)) ~to_:(Some (8, 1))
  in
  let before = Animation.cells animation ~width:20 ~height:5 in
  let unchanged = Animation.tick animation ~dt:0. in
  print_s
    [%sexp
      ([%equal: (int * int) list]
         (Animation.cells unchanged ~width:20 ~height:5)
         before
       : bool)];
  let delayed = Animation.tick animation ~dt:0.2 in
  print_s [%sexp (Animation.active delayed : bool)];
  [%expect
    {|
    true
    false
    |}]
;;

let%expect_test "Space v s enables the cursor effect without touching the editor" =
  let text =
    Text_buffer.of_string "hello"
    |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
    |> Result.ok_or_failwith
  in
  let controller = Ches_app.Controller.create (Ches_core.Editor.create ~path:"f" ~cell_width:Cell_map.width text) in
  let ui = Ui_state.create ~tiles_visible:false controller in
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
