open! Core
open Bonsai_test
open Bonsai_term
open Ches_core

let handle ?(width = 40) ?(height = 6) ?(document_only = true) s =
  let text =
    Result.ok_or_failwith
      (Result.map_error
         (Text_buffer.of_string s)
         ~f:Text_buffer.Invalid_text.to_string_hum)
  in
  let controller = Ches_app.Controller.create (Editor.create ~path:"f.txt" ~cell_width:Ches_screen.Cell_map.width text) in
  let exit () = Bonsai_term.Effect.print_s [%sexp "EXIT"] in
  let handle =
    Bonsai_term_test.create_handle (Ches_ui.Editor_view.app controller ~exit)
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
