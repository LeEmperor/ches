open! Core
open Ches_screen
module U = Ui_state
module K = Ches_input.Key
module M = Ches_terminal.Model

let width = 80
let height = 24
let run t inputs = Helpers.run ~width ~height t inputs
let at ms = Time_ns.add Time_ns.epoch (Time_ns.Span.of_ms (Float.of_int ms))
let editor ms c : U.Input.t = Key_at { key = K.char c; at = at ms }
let terminal ?(modifiers = M.no_modifiers) ms c : U.Input.t =
  Terminal_key_at { key = { code = Char (Uchar.of_char c); modifiers }; at = at ms }
let tick ms : U.Input.t = Toggle_tick (at ms)
let chars ?(start = 0) ?(gap = 10) key text =
  List.mapi (String.to_list text) ~f:(fun i c -> key (start + i * gap) c)
let insert () = run (Helpers.ui "") (Helpers.keys "i")
let shell () = run (Helpers.ui "") (Helpers.keys " /") |> U.take_terminal_requests |> fst
let text t = Ches_core.Editor.text (Ches_app.Controller.editor (U.controller t))
  |> Ches_core.Text_buffer.to_string
let mode t = Ches_core.Editor.mode (Ches_app.Controller.editor (U.controller t))
let requests t = snd (U.take_terminal_requests t)
let sent text = List.map (String.to_list text) ~f:(fun c ->
  M.Key { code = Char (Uchar.of_char c); modifiers = M.no_modifiers })
let check_requests t expected =
  let actual = requests t in
  if not (List.equal M.equal_request actual expected) then
    raise_s [%message "requests differ" (actual : M.request list) (expected : M.request list)]
let check_sent t text = check_requests t (sent text)

let%test_unit "Insert selection consumes all keys and restores document Insert" =
  let t = run (insert ()) (chars ~gap:199 editor "12 /") in
  assert (U.terminal_visible t);
  [%test_eq: int] (U.terminal_number t) 12;
  [%test_eq: string] (text t) "";
  assert (Ches_core.Mode.equal (mode t) Insert);
  let t = run t (chars ~start:1000 terminal "12 /") in
  assert (not (U.terminal_visible t));
  let t = run t [ editor 2000 'a' ] in
  [%test_eq: string] (text t) "a";
  assert (Ches_core.Mode.equal (mode t) Insert)
;;

let%test_unit "each gap has an exact exclusive 200ms boundary" =
  let t = run (insert ()) [ editor 0 '1'; editor 199 '2'; editor 398 ' '; editor 597 '/' ] in
  assert (U.terminal_visible t);
  List.iter [ [ editor 0 ' '; editor 200 '/' ]
            ; [ editor 0 '1'; editor 200 '2'; editor 400 ' '; editor 600 '/' ] ]
    ~f:(fun keys ->
      let t = run (insert ()) keys in
      assert (not (U.terminal_visible t));
      [%test_eq: string] (text t) (if List.length keys = 2 then " /" else "12 /"));
  let t = run (insert ()) [ editor 0 '1'; editor 199 '2'; tick 398 ] in
  assert (U.toggle_key_pending t);
  [%test_eq: string] (text t) "";
  let t = run t [ tick 399; tick 900 ] in
  assert (not (U.toggle_key_pending t));
  [%test_eq: string] (text t) "12"
;;

let%test_unit "literal prefixes, repetition, Unicode and editor jk replay" =
  List.iter [ " "; "123"; "0"; "000"; "12 x"; "  x"; "1a2b"; "1 jk" ] ~f:(fun s ->
    let t = run (insert ()) (chars editor s @ [ tick 1000 ]) in
    assert (not (U.terminal_visible t));
    [%test_eq: string] (text t) (if String.equal s "1 jk" then "1 " else s));
  let t = run (insert ()) [ editor 0 ' '; Key_at { key = K.Char (Uchar.of_scalar_exn 0x754c); at = at 10 } ] in
  [%test_eq: string] (text t) " 界";
  let t = run (insert ()) (chars editor "  /") in
  assert (U.terminal_visible t);
  [%test_eq: string] (text t) " "
;;

let%test_unit "max_int is accepted and arbitrarily long digits remain bounded and literal" =
  let max = Int.to_string Int.max_value in
  let t = run (insert ()) (chars editor (max ^ " /")) in
  [%test_eq: int] (U.terminal_number t) Int.max_value;
  let s = String.make 2000 '9' in
  let t = run (insert ()) (chars editor s @ [ tick 30000 ]) in
  [%test_eq: string] (text t) s;
  assert (not (U.toggle_key_pending t));
  let s = max ^ "0x" in
  let t = run (insert ()) (chars editor s @ [ tick 1000 ]) in
  [%test_eq: string] (text t) s
;;

let%test_unit "terminal jk ordering before match and after mismatched prefix" =
  let t = run (shell ()) (chars terminal "j /") in
  assert (not (U.terminal_visible t));
  check_sent t "j";
  let t = run (shell ()) (chars terminal "12 jk") in
  assert (Option.is_some (U.terminal_inspection t));
  check_sent t "12 ";
  let t = run (shell ()) (chars terminal "12 jx") in
  check_sent t "12 jx"
;;

let%test_unit "paste flushes a prefix and bypasses both recognizers and controls" =
  let t = run (insert ()) ([ editor 0 '1'; Paste_start ] @ chars editor "2 /jk" @ [ Paste_end ]) in
  [%test_eq: string] (text t) "12 /jk";
  assert (not (U.terminal_visible t));
  let t = run (shell ()) ([ terminal 0 '1'; Paste_start ]
    @ chars terminal "2 /jk" @ [ terminal ~modifiers:{ M.no_modifiers with ctrl = true } 50 ' '; Paste_end ]) in
  check_requests t (sent "1" @ [ M.Paste "2 /jk" ]);
  assert (Option.is_none (U.terminal_inspection t))
;;

let%test_unit "modifiers flush literally; shifted Space is printable" =
  List.iter [ { M.no_modifiers with alt = true }; { M.no_modifiers with ctrl = true } ]
    ~f:(fun modifiers ->
      let t = run (shell ()) [ terminal 0 '1'; terminal ~modifiers 10 '/'; terminal 20 '/' ] in
      check_requests t
        (sent "1" @ [ M.Key { code = Char (Uchar.of_char '/'); modifiers } ] @ sent "/"));
  let t = run (shell ()) [ terminal ~modifiers:{ M.no_modifiers with shift = true } 0 ' '; terminal 10 '/' ] in
  assert (not (U.terminal_visible t));
  check_sent t "";
  let modifiers = { M.no_modifiers with shift = true } in
  let t = run (shell ()) [ terminal ~modifiers 0 ' '; terminal 10 'x' ] in
  check_requests t ([ M.Key { code = Char (Uchar.of_char ' '); modifiers } ] @ sent "x")
;;

let%test_unit "output and fitting resize preserve timeout; exit and ownership loss cancel" =
  let t = run (shell ()) [ terminal 0 '2'; Resize; Terminal (Snapshot (Test_terminal.snapshot ())); terminal 100 ' '; terminal 199 '/' ] in
  [%test_eq: int] (U.terminal_number t) 2;
  let t = run (shell ()) [ terminal 0 '2'; Terminal (Failed "exit") ] in
  assert (not (U.toggle_key_pending t));
  check_sent t "";
  let t = Helpers.run ~width:10 ~height:3 (run (shell ()) [ terminal 0 '2' ]) [ Resize ] in
  assert (not (U.toggle_key_pending t));
  let t = run t [ tick 1000 ] in
  check_sent t ""
;;

let%test_unit "numbered terminal requests retain their original owner" =
  let t = run (shell ()) (chars terminal "j2 /") in
  [%test_eq: int] (U.terminal_number t) 2;
  let t, requests = U.take_terminal_session_requests t in
  (match requests with
   | [ (1, Key key); (2, Start _) ] ->
     assert (M.equal_key key { code = Char (Uchar.of_char 'j'); modifiers = M.no_modifiers })
   | _ -> raise_s [%message "unexpected requests" (requests : (int * M.request) list)]);
  let t = run t (chars ~start:1000 terminal "2 /") in
  assert (not (U.terminal_visible t));
  let t = run t (Helpers.keys "1 /") in
  [%test_eq: int] (U.terminal_number t) 1;
  assert (U.terminal_visible t);
  check_sent t ""
;;

let%test_unit "terminal literals, repeated mismatch, timeout and Unicode retain exact order" =
  List.iter [ " "; "123"; "000"; "12 x"; "  x"; "1a2b"; String.make 1000 '9' ] ~f:(fun s ->
    let t = run (shell ()) (chars terminal s @ [ tick 30000 ]) in
    check_sent t s;
    assert (not (U.toggle_key_pending t)));
  let t = run (shell ()) [ terminal 0 ' '; terminal 200 '/' ] in
  check_sent t " /";
  let t = run (shell ()) [ terminal 0 ' '; Terminal_key_at {
    key = { code = Char (Uchar.of_scalar_exn 0x754c); modifiers = M.no_modifiers }; at = at 10 } ] in
  check_requests t (sent " " @ [ M.Key {
    code = Char (Uchar.of_scalar_exn 0x754c); modifiers = M.no_modifiers } ])
;;

let%test_unit "editor lifecycle never replays into another buffer or a reopened lifetime" =
  Test_session_ui.with_files (fun a b ->
    let initial = Test_session_ui.create a in
    let aid = Option.value_exn (Ches_app.Session.active_id (U.session initial)) in
    let pending = run initial (Helpers.keys "i" @ [ editor 0 '1' ]) in
    let t, _ = U.open_file pending ~width ~height b |> Or_error.ok_exn in
    assert (not (U.toggle_key_pending t));
    let before_b = text t in
    let t = run t [ tick 1000 ] in
    [%test_eq: string] (text t) before_b;
    let t = U.activate_buffer t ~width ~height aid |> Or_error.ok_exn in
    let t = run t [ tick 1000 ] in
    [%test_eq: string] (text t) (text initial);
    let pending = run initial (Helpers.keys "i" @ [ editor 0 '2' ]) in
    let t, closed = U.close_current pending ~width ~height ~force:true in
    assert closed;
    let t, reopened = U.open_file t ~width ~height a |> Or_error.ok_exn in
    assert (not (Ches_app.Buffer_id.equal aid reopened));
    let t = run t [ tick 1000 ] in
    [%test_eq: string] (text t) (text initial))
;;

let%test_unit "stale and background session exits preserve the current prefix" =
  let t = run (shell ()) (chars terminal "2 /") |> U.take_terminal_requests |> fst in
  let generation = U.terminal_generation t in
  let t = run t [ terminal 100 '3'
    ; Terminal_session_update { terminal = 1; generation; event = Failed "background" }
    ; Terminal_session_update { terminal = 2; generation = generation - 1; event = Failed "stale" }
    ; terminal 200 ' '; terminal 300 '/' ] in
  [%test_eq: int] (U.terminal_number t) 3;
  let t, requests = U.take_terminal_session_requests t in
  (match requests with [ (3, Start _) ] -> () | _ -> assert false);
  let t = run t [ terminal 400 '4'
    ; Terminal_session_update { terminal = 3; generation = U.terminal_generation t; event = Failed "exit" }
    ; tick 1000 ] in
  assert (not (U.toggle_key_pending t));
  check_sent t ""
;;

let%test_unit "Normal and Visual leaders remain untimed and counts retain their path" =
  List.iter [ ""; "v" ] ~f:(fun prefix ->
    let t = run (Helpers.ui "abc") (Helpers.keys prefix @ chars ~gap:1000 editor "2 /") in
    [%test_eq: int] (U.terminal_number t) 2;
    assert (U.terminal_visible t));
  let ctrl_space : U.Input.t = Terminal_key_at {
    key = { code = Char (Uchar.of_char ' '); modifiers = { M.no_modifiers with ctrl = true } }; at = at 0 } in
  List.iter [ ""; "v" ] ~f:(fun prefix ->
    let t = run (shell ()) ([ ctrl_space ] @ chars ~start:1000 terminal prefix
      @ chars ~start:2000 ~gap:1000 terminal "2 /") in
    [%test_eq: int] (U.terminal_number t) 2;
    assert (U.terminal_visible t))
;;
