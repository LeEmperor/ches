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

let%test_unit "frontend keeps terminal capture through Ctrl-Space variants and Visual" =
  let module U = Ches_screen.Ui_state in
  let module M = Ches_terminal.Model in
  let text = Result.ok (Ches_core.Text_buffer.of_string "unchanged") |> Option.value_exn in
  let controller = Ches_app.Controller.create
      (Ches_core.Editor.create ~cell_width:Ches_screen.Cell_map.width text) in
  let cache = Ches_screen.Frame.Cache.create () in
  let initial = U.create ~bare:true controller in
  let feed ui event =
    let inputs = Terminal_input.inputs ~terminal:(U.terminal_capturing ui) event in
    fst (Ches_screen.Frame.Cache.apply_inputs cache ui ~width:120 ~height:40 inputs) in
  let chars ui s = List.fold (String.to_list s) ~init:ui
      ~f:(fun ui c -> feed ui (key (ASCII c))) in
  List.iter [ key ~mods:[ Ctrl ] (ASCII ' ')
            ; key ~mods:[ Ctrl ] (ASCII '@'); key (ASCII '\000') ] ~f:(fun normal ->
    let ui = chars initial " /" in
    assert (U.terminal_capturing ui);
    let ui, _ = U.take_terminal_requests ui in
    let ui = feed ui normal in
    assert (U.terminal_capturing ui);
    assert (Option.is_some (U.terminal_inspection ui));
    let ui = chars ui "v" in
    assert (U.terminal_capturing ui);
    let ui = feed ui (key Escape) |> fun ui -> chars ui "i" in
    assert (U.terminal_capturing ui);
    assert (Option.is_none (U.terminal_inspection ui));
    let ui = feed ui (key Escape) in
    let ui, requests = U.take_terminal_requests ui in
    assert (List.equal M.equal_request requests
      [ M.Key { code = Escape; modifiers = M.no_modifiers } ]);
    let ui = feed ui normal |> fun ui -> chars ui " /" in
    assert (not (U.terminal_capturing ui)))
;;

let%test_unit "terminal capture preserves every key and modifier combination" =
  let module M = Ches_terminal.Model in
  let keys : (Event.Key.t * M.key_code) list =
    ([ Escape, Escape; Tab, Tab; Backspace, Backspace
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

let%test_unit "Notty LF remains Ctrl-J and CR remains Enter" =
  let module M = Ches_terminal.Model in
  let decode bytes =
    let decoder = Notty.Unescape.create () in
    Notty.Unescape.input decoder (Bytes.of_string bytes) 0 (String.length bytes);
    match Notty.Unescape.next decoder with
    | `Key (`Enter, []) -> key Enter
    | `Key (`ASCII c, [ `Ctrl ]) -> key ~mods:[ Ctrl ] (ASCII c)
    | _ -> failwith "unexpected newline decoding"
  in
  List.iter [ "\n", 'j'; "\r", 'M' ] ~f:(fun (bytes, c) ->
    let event = decode bytes in
    (match Terminal_input.inputs ~terminal:true event with
     | [ Terminal_key actual ] ->
       assert (M.equal_key actual
         { code = M.Char (Uchar.of_char c)
         ; modifiers = { M.no_modifiers with ctrl = true } })
     | _ -> failwith "newline key lost");
    match Terminal_input.inputs event with
    | [ Key Enter ] -> ()
    | _ -> failwith "editor Enter lost")
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

let%test_unit "frontend normalizes Insert navigation without synthesizing paste text" =
  let module U = Ches_screen.Ui_state in
  let module E = Ches_core.Editor in
  let text = Ches_core.Text_buffer.of_string "界é\nnext" |> Result.ok |> Option.value_exn in
  let controller = Ches_app.Controller.create (E.create ~cell_width:Ches_screen.Cell_map.width text) in
  let feed ui event = fst (U.apply_all ui ~width:80 ~height:10 (Terminal_input.inputs event)) in
  let ui = U.create ~bare:true controller |> fun ui -> feed ui (key (ASCII 'i')) in
  let ui = List.fold [key End; key (Arrow `Left); key (ASCII 'X'); key Home; key (Arrow `Right)]
      ~init:ui ~f:feed in
  let editor = Ches_app.Controller.editor (U.controller ui) in
  assert (String.equal (Ches_core.Text_buffer.to_string (E.text editor)) "界Xé\nnext");
  assert (E.cursor editor = 3);
  List.iter [ Event.Key.Arrow `Left, Ches_input.Key.Left; Arrow `Right, Right; Home, Home; End, End ]
    ~f:(fun (native, normalized) ->
      assert (Option.is_none (Ches_input.Key.text normalized));
      match Terminal_input.inputs (key native) with
      | [Key actual] -> assert (Ches_input.Key.equal actual normalized)
      | _ -> assert false)
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
    ((Key_press (key (Arrow Left))) -> ((Key Left)))
    ((Key_press (key (Function 1))) -> ())
    ((Paste Start) -> (Paste_start))
    ((Paste End) -> (Paste_end))
    ((Mouse (kind Left) (position ((x 0) (y 0)))) -> ())
    |}]
;;
