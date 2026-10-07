open! Core
open Ches_source
module Source_event = Ches_error.Source_event

let diagnostics ?(source = "a") ?(resource = "f.ml") revision : Source_event.t =
  Diagnostics { source; resource; revision = Some revision; findings = [] }
;;

let show queue =
  let queue, events = Event_queue.take queue ~max:100 in
  List.iter events ~f:(fun event ->
    print_s
      (match event with
       | Owned _ -> [%message "owned"]
       | Diagnostics { source; resource; revision; _ } ->
         [%message "diagnostics" source resource (revision : int option)]
       | Started { source; _ } -> [%message "started" source]
       | Stopped { source; _ } -> [%message "stopped" source]
       | Unavailable { source; _ } -> [%message "unavailable" source]));
  print_s [%message (Event_queue.dropped queue : int) (Event_queue.length queue : int)]
;;

let push_all events = List.fold events ~init:Event_queue.empty ~f:Event_queue.push

let%expect_test "only the newest snapshot per (source, resource) waits" =
  show
    (push_all
       [ diagnostics 1
       ; diagnostics ~source:"b" 1
       ; diagnostics ~resource:"g.ml" 1
       ; diagnostics 2
       ; diagnostics 3
       ]);
  [%expect
    {|
    (diagnostics b f.ml (revision (1)))
    (diagnostics a g.ml (revision (1)))
    (diagnostics a f.ml (revision (3)))
    (("Event_queue.dropped queue" 2) ("Event_queue.length queue" 0))
    |}]
;;

let%expect_test "lifecycle events are kept, and snapshots never cross their source's" =
  show
    (push_all
       [ diagnostics 1
       ; Stopped { source = "a"; root = "/"; reason = "crash" }
       ; diagnostics ~source:"b" 1
       ; Started { source = "a"; root = "/" }
       ; diagnostics 2
       ; diagnostics ~source:"b" 2
       ; diagnostics 3
       ]);
  [%expect
    {|
    (diagnostics a f.ml (revision (1)))
    (stopped a)
    (started a)
    (diagnostics b f.ml (revision (2)))
    (diagnostics a f.ml (revision (3)))
    (("Event_queue.dropped queue" 2) ("Event_queue.length queue" 0))
    |}]
;;

let%expect_test "take is bounded and oldest first" =
  let queue =
    push_all (List.init 5 ~f:(fun i -> diagnostics ~resource:(sprintf "%d.ml" i) 1))
  in
  let queue, first = Event_queue.take queue ~max:2 in
  print_s [%message (List.length first : int) (Event_queue.length queue : int)];
  show queue;
  [%expect
    {|
    (("List.length first" 2) ("Event_queue.length queue" 3))
    (diagnostics a 2.ml (revision (1)))
    (diagnostics a 3.ml (revision (1)))
    (diagnostics a 4.ml (revision (1)))
    (("Event_queue.dropped queue" 0) ("Event_queue.length queue" 0))
    |}]
;;
