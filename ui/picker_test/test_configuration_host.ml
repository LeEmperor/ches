open! Core
open! Async
open Bonsai_test
open Bonsai_term
module Expect_test_config = Async.Expect_test_config
module Host = Ches_ui.Configuration_host
module Settings = Ches_config_runtime.Settings

let within deferred =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) deferred with
  | `Result result -> result
  | `Timeout -> failwith "configuration integration timed out"
;;

let%expect_test "startup awaits loader; reload coalesces and stop ignores active work" =
  let gates = Queue.create () in
  let calls = ref 0 in
  let host = Host.create ~load:(fun () ->
    incr calls;
    let gate = Ivar.create () in Queue.enqueue gates gate; Ivar.read gate) () in
  let startup = Host.startup host in
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  assert (!calls = 1 && not (Deferred.is_determined startup));
  Ivar.fill_exn (Queue.dequeue_exn gates) (Ok Settings.default);
  let%bind settings = within startup in
  assert (Settings.equal (Result.ok_or_failwith settings) Settings.default);
  Host.submit host [ 1 ];
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  Host.submit host [ 2; 3; 4; 2 ];
  assert (!calls = 2);
  let reply = Host.next host in
  Ivar.fill_exn (Queue.dequeue_exn gates) (Error "obsolete error");
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  assert (!calls = 3 && not (Deferred.is_determined reply));
  Ivar.fill_exn (Queue.dequeue_exn gates) (Ok { Settings.default with theme = "glacier" });
  let%bind result = within reply in
  let generation, settings = Option.value_exn result in
  assert (generation = 4 && String.equal (Result.ok_or_failwith settings).theme "glacier");
  Host.submit host [ 5 ];
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  Host.submit host [ 6 ];
  let waiting = Host.next host in
  let shutdown = Host.shutdown host in
  assert (not (Deferred.is_determined shutdown));
  let%bind stopped = within waiting in
  assert (Option.is_none stopped);
  Ivar.fill_exn (Queue.dequeue_exn gates) (Ok Settings.default);
  let%bind () = within shutdown in
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  Host.submit host [ 7 ];
  assert (!calls = 4);
  print_endline "startup ordering, latest-only reload and stop passed";
  [%expect {| startup ordering, latest-only reload and stop passed |}];
  return ()
;;

let%expect_test "injected loader exceptions become startup and reload diagnostics" =
  let host = Host.create ~load:(fun () -> failwith "injected loader exception") () in
  let check = function
    | Error error -> assert (String.is_substring error ~substring:"injected loader exception")
    | Ok _ -> failwith "expected loader diagnostic" in
  let%bind startup = within (Host.startup host) in
  check startup;
  Host.submit host [ 1 ];
  let%bind reply = within (Host.next host) in
  check (snd (Option.value_exn reply));
  Host.stop host;
  print_endline "loader exceptions are diagnostic results";
  [%expect {| loader exceptions are diagnostic results |}];
  return ()
;;

let controller () = Ches_app.Controller.create (Ches_core.Editor.create
  ~cell_width:Ches_screen.Cell_map.width Ches_core.Text_buffer.empty)
;;

let%expect_test "real startup snapshot, frontend reload, failure, CLI override and session-only changes" =
  let root = Filename_unix.temp_dir "ches-configuration-ui" "" in
  let path = Filename.concat root "config.ml" in
  let source = "open Ches_config\nlet () = Theme.set \"glacier\"; View.set_line_numbers true\n" in
  Out_channel.write_all path ~data:source;
  Monitor.protect (fun () ->
    let startup_host = Host.create ~load:(fun () -> Ches_config_runtime.Loader.load ~path ()) () in
    let%bind startup_configuration = within (Host.startup startup_host) in
    assert (String.equal (Result.ok_or_failwith startup_configuration).theme "glacier");
    let gates = Queue.create () in
    let calls = ref 0 in
    let configuration = Host.create ~load:(fun () ->
      incr calls;
      let gate = Ivar.create () in Queue.enqueue gates gate; Ivar.read gate) () in
    let make ?theme ?startup_configuration () =
      let controller = controller () in
      let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 160; height = 30 }
        (Ches_ui.Editor_view.app ~configuration ?startup_configuration ?theme ~bare:true controller
          ~exit:(fun () -> Effect.Ignore)) in
      handle, controller in
    let handle, controller = make ~startup_configuration () in
    let key key = Bonsai_term_test.send_event handle (Key_press { key; mods = [] }) in
    let type_text text = String.iter text ~f:(fun c -> key (ASCII c)) in
    let view () =
      Handle.recompute_view handle;
      Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
      [%expect.output] in
    let cell handle =
      Handle.recompute_view handle;
      let buffer = Buffer.create 64 in
      Notty.Render.to_buffer buffer Notty.Cap.ansi (0, 0) (1, 1)
        (View.Private.notty_image (Bonsai_term_test.last_view handle));
      Buffer.contents buffer in
    let wait predicate =
      let rec loop () =
        if predicate (view ()) then return () else
        let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 2) in loop () in
      within (loop ()) in
    let initial_color = cell handle in
    let%bind () = Scheduler.yield_until_no_jobs_remain () in
    ignore (view () : string);
    assert (!calls = 0);
    type_text "iEDITING"; key Escape;
    type_text " ccReload configuration"; key Enter;
    let%bind () = wait (fun _ -> !calls = 1) in
    type_text "AMORE"; key Escape;
    assert (String.is_substring (view ()) ~substring:"EDITINGMORE");
    Ivar.fill_exn (Queue.dequeue_exn gates) (Error "fixture configuration failure");
    let%bind () = wait (fun output -> String.is_substring output ~substring:"fixture configuration failure") in
    assert (String.equal (cell handle) initial_color);
    type_text " ccReload configuration"; key Enter;
    let%bind () = wait (fun _ -> !calls = 2) in
    Ivar.fill_exn (Queue.dequeue_exn gates) (Ok Settings.default);
    let%bind () = wait (fun _ -> not (String.equal (cell handle) initial_color)) in
    assert (String.is_substring (view ()) ~substring:"EDITINGMORE");
    let document_row output = List.find_exn (String.split_lines output)
      ~f:(fun line -> String.is_substring line ~substring:"EDITINGMORE") in
    let default_row = document_row (view ()) in
    type_text " vn";
    assert (not (String.equal (document_row (view ())) default_row));
    let toggled_color = cell handle in
    type_text " ccReload configuration"; key Enter;
    let%bind () = wait (fun _ -> !calls = 3) in
    type_text " ccReload configuration"; key Enter;
    ignore (view () : string);
    assert (!calls = 3);
    Ivar.fill_exn (Queue.dequeue_exn gates) (Ok { Settings.default with theme = "glacier" });
    let%bind () = wait (fun _ -> !calls = 4) in
    assert (String.equal (cell handle) toggled_color);
    Ivar.fill_exn (Queue.dequeue_exn gates) (Ok Settings.default);
    let%bind () = wait (fun output ->
      String.equal (document_row output) default_row) in
    assert (String.is_substring (view ()) ~substring:"EDITINGMORE");
    assert (String.equal (In_channel.read_all path) source);
    let crimson = Option.value_exn (Ches_theme.Theme.find "crimson") in
    let overridden, overridden_controller = make ~theme:crimson ~startup_configuration () in
    let default, default_controller = make ~theme:crimson () in
    assert (String.equal (cell overridden) (cell default));
    let failed, failed_controller = make ~startup_configuration:(Error "startup fixture diagnostic") () in
    Handle.recompute_view failed;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view failed);
    assert (String.is_substring ([%expect.output]) ~substring:"startup fixture diagnostic");
    Host.stop configuration;
    Host.stop startup_host;
    List.iter [ controller; overridden_controller; default_controller; failed_controller ]
      ~f:Ches_app.Controller.close;
    ignore ([%expect.output] : string);
    print_endline "real startup, asynchronous reload, error preservation, buffer preservation, explicit theme and no writes passed";
    [%expect {| real startup, asynchronous reload, error preservation, buffer preservation, explicit theme and no writes passed |}];
    return ())
    ~finally:(fun () -> Core_unix.unlink path; Core_unix.rmdir root; return ())
;;
