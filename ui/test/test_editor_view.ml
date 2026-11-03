open! Core
open Bonsai_test
open Bonsai_term
open Ches_core

let handle ?theme ?zen ?bare ?(width = 40) ?(height = 6) ?(document_only = true) s =
  let text =
    Result.ok_or_failwith
      (Result.map_error
         (Text_buffer.of_string s)
         ~f:Text_buffer.Invalid_text.to_string_hum)
  in
  let controller = Ches_app.Controller.create (Editor.create ~path:"f.txt" ~cell_width:Ches_screen.Cell_map.width text) in
  let exit () = Bonsai_term.Effect.print_s [%sexp "EXIT"] in
  let handle =
    Bonsai_term_test.create_handle (Ches_ui.Editor_view.app
      ~configuration_path:(Error "No configuration path in this rendering fixture")
      ?theme ?zen ?bare controller ~exit)
  in
  Bonsai_term_test.set_dimensions handle { width; height };
  (* These geometry scenarios predate the default-visible workspace companions.
     Select their document-only fixture explicitly, rather than snapshotting a
     different layout or changing production defaults to satisfy old expectations. *)
  if document_only then
    List.iter (String.to_list " vt vb vm0") ~f:(fun key ->
      Bonsai_term_test.send_event handle (Key_press { key = ASCII key; mods = [] }));
  handle
;;

let send handle keys =
  List.iter keys ~f:(fun (key, mods) ->
    Bonsai_term_test.send_event handle (Key_press { key; mods }))
;;

let chars s = List.map (String.to_list s) ~f:(fun c -> Event.Key.ASCII c, [])

let%expect_test "frontend Zen opt-in, Workspace default, and Bare startup precedence" =
  let create ?zen ?bare () =
    handle ?zen ?bare ~document_only:false ~width:100 ~height:30 "hello\nworld\n" in
  let frame handle =
    Handle.recompute_view handle;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    [%expect.output] in
  let workspace = create () in
  let explicit_workspace = create ~zen:false () in
  let zen = create ~zen:true () in
  let bare = create ~zen:true ~bare:true () in
  let bare_workspace = create ~zen:false ~bare:true () in
  let workspace_frame = frame workspace in
  assert (String.equal workspace_frame (frame explicit_workspace));
  assert (String.is_substring workspace_frame ~substring:"Problems");
  let zen_frame = frame zen in
  assert (not (String.is_substring zen_frame ~substring:"Problems"));
  assert (String.is_substring zen_frame ~substring:"╭─ f.txt");
  let bare_frame = frame bare in
  assert (not (String.is_substring bare_frame ~substring:"╭─ f.txt"));
  assert (String.equal bare_frame (frame bare_workspace));
  send zen (chars " vz");
  assert (String.is_substring (frame zen) ~substring:"Problems");
  send bare (chars " vB");
  assert (String.is_substring (frame bare) ~substring:"Problems");
  printf "Workspace default; Zen keeps its border and toggles back; Bare wins and returns to Workspace\n";
  [%expect {| Workspace default; Zen keeps its border and toggles back; Bare wins and returns to Workspace |}]
;;

let%expect_test "theme preview recolors real views, cancels, accepts and stays instance-local" =
  let find id = Option.value_exn (Ches_theme.Theme.find id) in
  let create theme =
    handle ~theme ~bare:true ~document_only:false ~width:120 ~height:40 "same text\n" in
  let crimson = create (find "crimson") in
  let glacier = create (find "glacier") in
  let cell handle =
    Bonsai_test.Handle.recompute_view handle;
    let buffer = Buffer.create 64 in
    Notty.Render.to_buffer buffer Notty.Cap.ansi (0, 0) (1, 1)
      (View.Private.notty_image (Bonsai_term_test.last_view handle));
    Buffer.contents buffer in
  let original = cell crimson in
  let light = cell glacier in
  assert (not (String.equal original light));
  send crimson (chars " vTglacier");
  assert (String.equal (cell crimson) light);
  send crimson [ Escape, [] ];
  assert (String.equal (cell crimson) original);
  send crimson (chars " ccChoose theme" @ [ Event.Key.Enter, [] ] @ chars "glacier");
  assert (String.equal (cell crimson) light);
  send crimson [ Enter, [] ];
  assert (String.equal (cell crimson) light);
  send crimson (chars " vTcrimson" @ [ Enter, [] ]);
  assert (String.equal (cell crimson) original);
  assert (String.equal (cell glacier) light);
  ignore ([%expect.output] : string);
  printf "same text: preview, cancel, accept, recovery and independent instances retain correct colors\n";
  [%expect {| same text: preview, cancel, accept, recovery and independent instances retain correct colors |}]
;;

let%expect_test "frontend Tab and terminal Shift-Tab navigate palette, not focus; Enter runs selection" =
  let handle = handle ~width:60 ~height:10 "first\nsecond\nthird" in
  send handle (chars " ccgutter" @ [ Tab, []; Tab, [ Event.Modifier.Shift ] ]);
  Handle.show handle;
  [%expect {|
    (cursor (((position ((x 11) (y 2))) (kind Bar))))
    ┌────────────────────────────────────────────────────────────┐
    │╭─ f.txt ──────────────────────────────────────────────────╮│
    ││╭─ Commands ─────────────────────────────────────────────╮││
    │││ > gutter                                               │││
    │││ > Toggle absolute line numbers               Space v n │││
    │││   Toggle relative line numbers               Space v N │││
    │││                                                        │││
    │││                                                        │││
    │││                                                        │││
    │╰╰─ 1/2 ──────────────────────────────────────────────────╯╯│
    │ NORMAL  f.txt                                          1:1 │
    └────────────────────────────────────────────────────────────┘
    |}];
  (* Back at the first result after Shift-Tab; refine without changing selection,
     then navigate to the second result and accept it through the frontend. *)
  send handle (chars " " @ [ Backspace, []; Tab, []; Enter, [] ]);
  Handle.show handle;
  [%expect {|
    (cursor (((position ((x 7) (y 1))) (kind Block))))
    ┌────────────────────────────────────────────────────────────┐
    │╭─ f.txt ──────────────────────────────────────────────────╮│
    ││    0 first                                               ││
    ││    1 second                                              ││
    ││    2 third                                               ││
    ││                                                          ││
    ││                                                          ││
    ││                                                          ││
    ││                                                          ││
    │╰──────────────────────────────────────────────────────────╯│
    │ NORMAL  f.txt Line numbers: relative                   1:1 │
    └────────────────────────────────────────────────────────────┘
    |}];
  send handle (chars " ccgutter" @ [ Tab, []; Escape, [] ]);
  Handle.show handle;
  [%expect {|
    (cursor (((position ((x 7) (y 1))) (kind Block))))
    ┌────────────────────────────────────────────────────────────┐
    │╭─ f.txt ──────────────────────────────────────────────────╮│
    ││    0 first                                               ││
    ││    1 second                                              ││
    ││    2 third                                               ││
    ││                                                          ││
    ││                                                          ││
    ││                                                          ││
    ││                                                          ││
    │╰──────────────────────────────────────────────────────────╯│
    │ NORMAL  f.txt Line numbers: relative                   1:1 │
    └────────────────────────────────────────────────────────────┘
    |}]
;;

let%expect_test "startup shows the installed workspace companions" =
  let handle = handle ~document_only:false "hello\nworld\n" in
  Handle.show handle;
  [%expect {|
    (cursor (((position ((x 0) (y 0))) (kind Block))))
    ┌────────────────────────────────────────┐
    │hello            NORMAL                 │
    │world            f.txt                  │
    │                 1:1                    │
    │╭─ Problems (wor> ╮ ╭─ History: 0 ent> ╮│
    ││ No active prob> │ │ No history       ││
    │╰─────────────────╯ ╰──────────────────╯│
    └────────────────────────────────────────┘
    |}]
;;

let%expect_test "the app renders, edits, and follows resizes" =
  let handle = handle "hello\nworld\n" in
  Handle.show handle;
  [%expect
    {|
    (cursor (((position ((x 3) (y 1))) (kind Block))))
    ┌────────────────────────────────────────┐
    │╭─ f.txt ──────────────────────────────╮│
    ││  hello                               ││
    ││  world                               ││
    ││                                      ││
    │╰──────────────────────────────────────╯│
    │ NORMAL  f.txt                      1:1 │
    └────────────────────────────────────────┘
    |}];
  send handle (chars "jix" @ [ Escape, [] ]);
  Handle.show handle;
  [%expect
    {|
    (cursor (((position ((x 3) (y 2))) (kind Block))))
    ┌────────────────────────────────────────┐
    │╭─ f.txt ──────────────────────────────╮│
    ││  hello                               ││
    ││  xworld                              ││
    ││                                      ││
    │╰──────────────────────────────────────╯│
    │ NORMAL  f.txt [+]                  2:1 │
    └────────────────────────────────────────┘
    |}];
  Bonsai_term_test.set_dimensions handle { width = 12; height = 3 };
  Handle.show handle;
  [%expect
    {|
    (cursor (((position ((x 0) (y 1))) (kind Block))))
    ┌────────────┐
    │hello       │
    │xworld      │
    │ NORMAL     │
    └────────────┘
    |}]
;;

let%expect_test "events in one frame all apply, in order" =
  let handle = handle "" in
  (* No recompute between these: each must see the state the previous one left. *)
  send handle (chars "iabc" @ [ Escape, []; ASCII 'x', [] ]);
  Handle.show handle;
  [%expect
    {|
    ([write_string_to_tty] (string "\027]52;c;Yw==\007"))
    (cursor (((position ((x 4) (y 1))) (kind Block))))
    ┌────────────────────────────────────────┐
    │╭─ f.txt ──────────────────────────────╮│
    ││  ab                                  ││
    ││                                      ││
    ││                                      ││
    │╰──────────────────────────────────────╯│
    │ NORMAL  f.txt [+]                  1:2 │
    └────────────────────────────────────────┘
    |}]
;;

let%expect_test "Space q exits once; later input is ignored" =
  let handle = handle "abc" in
  send handle (chars " q x Q");
  Handle.recompute_view handle;
  [%expect {|
    EXIT
    (cursor (((position ((x 3) (y 1))) (kind Block))))
    |}]
;;

let%expect_test "Space v layout commands move the tile, and resizes keep the request" =
  let handle = handle ~width:50 ~height:6 "abc" in
  (* Width 100 down to 30, then 10 cells right. *)
  send handle (chars (String.concat (List.init 7 ~f:(fun _ -> " v-")) ^ " vL"));
  Handle.show handle;
  [%expect {|
    (cursor (((position ((x 19) (y 1))) (kind Block))))
    ┌──────────────────────────────────────────────────┐
    │                ╭─ f.txt ────────────────────────╮│
    │                │  abc                           ││
    │                │                                ││
    │                │                                ││
    │                ╰────────────────────────────────╯│
    │ NORMAL  f.txt Offset +10 (+8 fit)            1:1 │
    └──────────────────────────────────────────────────┘
    |}];
  Bonsai_term_test.set_dimensions handle { width = 40; height = 6 };
  Handle.show handle;
  [%expect {|
    (cursor (((position ((x 9) (y 1))) (kind Block))))
    ┌────────────────────────────────────────┐
    │      ╭─ f.txt ────────────────────────╮│
    │      │  abc                           ││
    │      │                                ││
    │      │                                ││
    │      ╰────────────────────────────────╯│
    │ NORMAL  f.txt Offset +10 (+8 fit)  1:1 │
    └────────────────────────────────────────┘
    |}];
  send handle (chars " vc");
  Handle.show handle;
  [%expect {|
    (cursor (((position ((x 3) (y 1))) (kind Block))))
    ┌────────────────────────────────────────┐
    │╭─ f.txt ──────────────────────────────╮│
    ││  abc                                 ││
    ││                                      ││
    ││                                      ││
    │╰──────────────────────────────────────╯│
    │ NORMAL  f.txt Full width           1:1 │
    └────────────────────────────────────────┘
    |}]
;;
