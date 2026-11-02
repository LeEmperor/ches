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

let%test_unit "terminal capture preserves every key and modifier combination" =
  let module M = Ches_terminal.Model in
  let keys : (Event.Key.t * M.key_code) list =
    ([ Escape, Escape; Enter, Enter; Tab, Tab; Backspace, Backspace
    ; Insert, Insert; Delete, Delete; Home, Home; End, End
    ; Arrow `Up, Up; Arrow `Down, Down; Arrow `Left, Left; Arrow `Right, Right
    ; Page `Up, Page_up; Page `Down, Page_down
    ; Uchar (Uchar.of_scalar_exn 0x1f642), Char (Uchar.of_scalar_exn 0x1f642)
    ] : (Event.Key.t * M.key_code) list)
    @ List.init 128 ~f:(fun n ->
      let c = Char.of_int_exn n in Event.Key.ASCII c, M.Char (Uchar.of_char c))
    @ List.init 35 ~f:(fun n -> Event.Key.Function (n + 1), M.Function (n + 1))
  in
  List.iter [ false; true ] ~f:(fun shift ->
    List.iter [ false; true ] ~f:(fun alt ->
      List.iter [ false; true ] ~f:(fun ctrl ->
        let mods = (if shift then [ Event.Modifier.Shift ] else [])
          @ (if alt then [ Event.Modifier.Meta ] else [])
          @ (if ctrl then [ Event.Modifier.Ctrl ] else []) in
        List.iter keys ~f:(fun (input, code) ->
          let expected : M.key = { code; modifiers = { shift; alt; ctrl } } in
          List.iter [ mods; List.rev mods ] ~f:(fun mods ->
            match Terminal_input.inputs ~terminal:true (key ~mods input) with
            | [ Terminal_key actual ] ->
              if not (M.equal_key actual expected) then
                raise_s [%message "terminal key mismatch" (actual : M.key) (expected : M.key)]
            | actual -> raise_s [%message "terminal key lost" (actual : Ches_screen.Ui_state.Input.t list)])))))
;;

let%test_unit "terminal capture retains paste boundaries and ignores mouse" =
  List.iter
    [ Event.Paste `Start; Event.Paste `End
    ; Event.Mouse { kind = Left; position = { x = 4; y = 2 }; mods = [ Ctrl ] } ]
    ~f:(fun event ->
      assert (String.equal
        (Sexp.to_string [%sexp (Terminal_input.inputs event : Ches_screen.Ui_state.Input.t list)])
        (Sexp.to_string [%sexp (Terminal_input.inputs ~terminal:true event : Ches_screen.Ui_state.Input.t list)])))
;;

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
