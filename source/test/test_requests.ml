(* What Ui_state asks a source, through [take_source_requests]. *)
open! Core
open! Async
open Ches_screen
module H = Harness

let recording requests ~time:_ ~root:_ =
  Ches_source.Source.create (fun ~emit:_ ->
    { handle = (fun request -> requests := request :: !requests); stop = ignore })
;;

let show t requests =
  List.iter (List.rev !requests) ~f:(fun (request : Ches_error.Source_request.t) ->
    print_s
      (match request with
       | Document_changed { resource; text; revision } ->
         [%message "changed" ~_:(H.relative t resource : string) text (revision : int)]
       | Document_saved { resource; revision } ->
         [%message "saved" ~_:(H.relative t resource : string) (revision : int)]
       | Restart -> [%message "restart"]
       | Kill -> [%message "kill"]));
  requests := []
;;

let%expect_test "initial text, changes, saves (also unchanged), restart and kill in order" =
  let requests = ref [] in
  let t = H.create ~text:"ab\n" ~source:(recording requests) () in
  H.send_requests t;
  show t requests;
  [%expect {| (changed a.ml "ab\n" (revision 0)) |}];
  (* Moving sends nothing; each edit's revision is sent once, however many keys. *)
  H.keys t "l";
  show t requests;
  [%expect {| |}];
  (* Keys applied in one transition send the newest text only, then the save, then the
     commands in the order given. *)
  H.keys t "x vRx w vK";
  show t requests;
  [%expect
    {|
    (changed a.ml "\n" (revision 2))
    (saved a.ml (revision 2))
    restart
    kill
    |}];
  H.keys t " w";
  show t requests;
  [%expect {| (saved a.ml (revision 2)) |}];
  return ()
;;

let%expect_test "nothing is requested without a source, and the commands say so" =
  let t = H.create ~text:"ab\n" ~source:(recording (ref [])) () in
  t.ui <- Ui_state.create (Ui_state.controller t.ui);
  H.keys t "x vR";
  let ui, requests = Ui_state.take_source_requests t.ui in
  t.ui <- ui;
  print_s [%message (List.length requests : int)];
  H.status t;
  [%expect
    {|
    ("List.length requests" 0)
    No diagnostic source; launch with --synthetic-checker
    |}];
  return ()
;;
