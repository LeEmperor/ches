open! Core
open Bonsai_test
open Bonsai_term
open Ches_core

let handle ?(width = 40) ?(height = 6) s =
  let text =
    Result.ok_or_failwith
      (Result.map_error
         (Text_buffer.of_string s)
         ~f:Text_buffer.Invalid_text.to_string_hum)
  in
  let controller = Ches_app.Controller.create (Editor.create ~path:"f.txt" text) in
  let exit () = Bonsai_term.Effect.print_s [%sexp "EXIT"] in
  let handle =
    Bonsai_term_test.create_handle (Ches_ui.Editor_view.app controller ~exit)
  in
  Bonsai_term_test.set_dimensions handle { width; height };
  handle
;;

let send handle keys =
  List.iter keys ~f:(fun (key, mods) ->
    Bonsai_term_test.send_event handle (Key_press { key; mods }))
;;

let chars s = List.map (String.to_list s) ~f:(fun c -> Event.Key.ASCII c, [])

let%expect_test "the app renders, edits, and follows resizes" =
  let handle = handle "hello\nworld\n" in
  Handle.show handle;
  [%expect
    {|
    (cursor (((position ((x 5) (y 1))) (kind Block))))
    ┌────────────────────────────────────────┐
    │┌──────────────────────────────────────┐│
    ││  1 hello                             ││
    ││  2 world                             ││
    ││  3                                   ││
    │└──────────────────────────────────────┘│
    │ NORMAL  f.txt                      1:1 │
    └────────────────────────────────────────┘
    |}];
  send handle (chars "jix" @ [ Escape, [] ]);
  Handle.show handle;
  [%expect
    {|
    (cursor (((position ((x 5) (y 2))) (kind Block))))
    ┌────────────────────────────────────────┐
    │┌──────────────────────────────────────┐│
    ││  1 hello                             ││
    ││  2 xworld                            ││
    ││  3                                   ││
    │└──────────────────────────────────────┘│
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
    (cursor (((position ((x 6) (y 1))) (kind Block))))
    ┌────────────────────────────────────────┐
    │┌──────────────────────────────────────┐│
    ││  1 ab                                ││
    ││                                      ││
    ││                                      ││
    │└──────────────────────────────────────┘│
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
    (cursor (((position ((x 5) (y 1))) (kind Block))))
    |}]
;;
