open! Core
open Bonsai_term
open Ches_ui

let show (event : Event.t) =
  print_s
    [%sexp
      (event : Event.t)
      , "->"
      , (Terminal_input.inputs event : Ches_screen.Ui_state.Input.t list)]
;;

let key ?(mods = []) key : Event.t = Key_press { key; mods }

let%expect_test "terminal events become normalized keys" =
  List.iter
    [ key (ASCII 'a')
    ; key (ASCII 'Q')
    ; key (ASCII ' ')
    ; key (Uchar (Uchar.of_scalar_exn 0x4E2D))
    ; key ~mods:[ Ctrl ] (ASCII 'C')
    ; key ~mods:[ Ctrl ] (ASCII 'r')
    ; key ~mods:[ Ctrl ] (ASCII '@')
    ; key Enter
    ; key Tab
    ; key ~mods:[ Shift ] Tab
    ; key Backspace
    ; key ~mods:[ Ctrl ] Backspace
    ; key Delete
    ; key Escape
    ; key ~mods:[ Meta ] (ASCII 'x')
    ; key ~mods:[ Meta ] (Arrow `Up)
    ; key (Arrow `Left)
    ; key (Function 1)
    ; Paste `Start
    ; Paste `End
    ; Mouse { kind = Left; position = { x = 0; y = 0 }; mods = [] }
    ]
    ~f:show;
  [%expect
    {|
    ((Key_press (key (ASCII a))) -> ((Key (Char U+0061))))
    ((Key_press (key (ASCII Q))) -> ((Key (Char U+0051))))
    ((Key_press (key (ASCII " "))) -> ((Key (Char U+0020))))
    ((Key_press (key (Uchar U+4E2D))) -> ((Key (Char U+4E2D))))
    ((Key_press (key (ASCII C)) (mods (Ctrl))) -> ((Key (Ctrl c))))
    ((Key_press (key (ASCII r)) (mods (Ctrl))) -> ((Key (Ctrl r))))
    ((Key_press (key (ASCII @)) (mods (Ctrl))) -> ())
    ((Key_press (key Enter)) -> ((Key Enter)))
    ((Key_press (key Tab)) -> ((Key Tab)))
    ((Key_press (key Tab) (mods (Shift))) -> ((Key Shift_tab)))
    ((Key_press (key Backspace)) -> ((Key Backspace)))
    ((Key_press (key Backspace) (mods (Ctrl))) -> ((Key (Ctrl h))))
    ((Key_press (key Delete)) -> ((Key Delete)))
    ((Key_press (key Escape)) -> ((Key Escape)))
    ((Key_press (key (ASCII x)) (mods (Meta))) ->
     ((Key Escape) (Key (Char U+0078))))
    ((Key_press (key (Arrow Up)) (mods (Meta))) -> ((Key Escape)))
    ((Key_press (key (Arrow Left))) -> ())
    ((Key_press (key (Function 1))) -> ())
    ((Paste Start) -> (Paste_start))
    ((Paste End) -> (Paste_end))
    ((Mouse (kind Left) (position ((x 0) (y 0)))) -> ())
    |}]
;;
