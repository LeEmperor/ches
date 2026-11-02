open! Core
open! Async

module Host = Ches_ui.Terminal_host

let within deferred =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 5) deferred with
  | `Result value -> value
  | `Timeout -> failwith "terminal frontend shutdown/event deadline exceeded"
;;

let%expect_test "shutdown releases the idle event pump and rejects subsequent starts" =
  let host = Host.create () in
  let pending = Host.next_event host in
  assert (not (Deferred.is_determined pending));
  let%bind () = within (Host.shutdown host) in
  let%bind event = within pending in
  assert (Option.is_none event);
  Host.submit host [ Start { cwd = "/"; rows = 3; cols = 20 } ];
  let%bind event = within (Host.next_event host) in
  assert (Option.is_none event);
  let%bind () = within (Host.shutdown host) in
  print_endline "idle pump cancelled; closed host stays closed";
  [%expect {| idle pump cancelled; closed host stays closed |}];
  return ()
;;

let%expect_test "one runtime publishes a shell snapshot and shuts down with a waiter" =
  let host = Host.create () in
  Monitor.protect
    (fun () ->
      Host.submit host [ Start { cwd = "/"; rows = 3; cols = 20 } ];
      let%bind event = within (Host.next_event host) in
      (match event with
       | Some (Snapshot snapshot) ->
         assert (Array.length snapshot.rows = 3);
         assert (Array.for_all snapshot.rows ~f:(fun row -> Array.length row = 20))
       | Some (Failed error) -> failwith error
       | None -> failwith "terminal closed before its initial snapshot");
      let pending = Host.next_event host in
      Host.stop host;
      let%bind () = within (Host.shutdown host) in
      let%bind event = within pending in
      assert (Option.is_none event);
      print_endline "snapshot delivered; child shutdown awaited; pump cancelled";
      [%expect {| snapshot delivered; child shutdown awaited; pump cancelled |}];
      return ())
    ~finally:(fun () -> within (Host.shutdown host))
;;

let%expect_test "updates retain the generation of publication, not when the consumer began waiting" =
  let host = Host.create () in
  Monitor.protect
    (fun () ->
      let pending = Host.next_update host in
      Host.submit host [ Start { cwd = "/"; rows = 0; cols = 20 } ];
      let%bind event = within pending in
      (match event with
       | Some (1, Failed _) -> ()
       | _ -> failwith "failed Start lost its generation");
      let pending = Host.next_update host in
      Host.submit host [ Start { cwd = "/"; rows = 3; cols = 20 } ];
      let%bind event = within pending in
      (match event with
       | Some (2, Snapshot snapshot) -> assert (Option.is_none snapshot.exited)
       | _ -> failwith "restarted shell lost its generation");
      print_endline "failed and successful starts retain distinct generations";
      [%expect {| failed and successful starts retain distinct generations |}];
      return ())
    ~finally:(fun () -> within (Host.shutdown host))
;;
