open! Core
open! Async
open Bonsai_test
open Bonsai_term
module Expect_test_config = Async.Expect_test_config
module Host = Ches_ui.Snippet_host
module Catalog = Ches_completion.User_snippets

let error_exn = function Error error -> error | Ok _ -> failwith "expected load failure"

let within deferred =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 5) deferred with
  | `Result result -> result
  | `Timeout -> failwith "snippet host timed out"
;;

let%expect_test "config path precedence" =
  let path xdg home = Host.config_path ~getenv:(function
    | "XDG_CONFIG_HOME" -> xdg | "HOME" -> home | _ -> None) in
  List.iter [ Some "/xdg"; Some "relative"; Some ""; None ] ~f:(fun xdg ->
    print_endline (Or_error.ok_exn (path xdg (Some "/home/test"))));
  assert (Result.is_error (path None None));
  assert (Result.is_ok (path (Some "/xdg") None));
  [%expect {|
    /xdg/ches/snippets.json
    /home/test/.config/ches/snippets.json
    /home/test/.config/ches/snippets.json
    /home/test/.config/ches/snippets.json
    |}];
  return ()
;;

let valid = {|{"version":1,"snippets":[{"id":"test","prefix":"zhost","body":"HOST_BODY"}]}|}

let%expect_test "bounded disk loader: missing, parsing, exact cap, overflow, special files and permissions" =
  let root = Filename_unix.temp_dir "ches-snippets" "" in
  let path = root ^ "/snippets.json" in
  let load () = within (Host.For_testing.load ~path) in
  let%bind () = Monitor.protect (fun () ->
    let%bind missing = load () in
    assert (phys_equal (Result.ok_or_failwith missing) Catalog.builtins);
    assert (not (Sys_unix.file_exists_exn path));
    Out_channel.write_all path ~data:valid;
    let%bind good = load () in
    assert (Result.is_ok good);
    Out_channel.write_all path ~data:"{broken";
    let%bind bad = load () in
    assert (Result.is_error bad);
    assert (String.is_substring (error_exn bad) ~substring:path);
    Out_channel.write_all path ~data:(valid ^ String.make (1024 * 1024 - String.length valid) ' ');
    let%bind exact = load () in
    assert (Result.is_ok exact);
    Out_channel.write_all path ~data:(String.make (1024 * 1024 + 1) ' ');
    let%bind large = load () in
    assert (String.is_substring (error_exn large) ~substring:"1 MiB");
    Out_channel.write_all path ~data:valid;
    Core_unix.chmod path ~perm:0;
    let%bind denied = load () in
    if Core_unix.geteuid () <> 0 then assert (Result.is_error denied);
    Core_unix.chmod path ~perm:0o600;
    Core_unix.unlink path;
    Core_unix.mkfifo path ~perm:0o600;
    let%bind fifo = load () in
    assert (String.is_substring (error_exn fifo) ~substring:"regular file");
    Core_unix.unlink path;
    Core_unix.mkdir path;
    let%bind directory = load () in
    assert (Result.is_error directory);
    Core_unix.rmdir path;
    return ()) ~finally:(fun () -> Core_unix.rmdir root; return ()) in
  print_endline "bounded loads passed";
  [%expect {| bounded loads passed |}];
  return ()
;;

let%expect_test "one active worker, one latest pending generation; stop wakes listeners" =
  let gates = Queue.create () in
  let calls = ref 0 in
  let host = Host.For_testing.create ~load:(fun () ->
    incr calls;
    let gate = Ivar.create () in Queue.enqueue gates gate; Ivar.read gate) in
  Host.submit host [ 1 ];
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  assert (!calls = 1);
  Host.submit host [ 2; 3; 4; 2 ];
  assert (!calls = 1);
  let reply = Host.next host in
  Ivar.fill_exn (Queue.dequeue_exn gates) (Error "obsolete error");
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  assert (!calls = 2);
  assert (not (Deferred.is_determined reply));
  Ivar.fill_exn (Queue.dequeue_exn gates) (Ok Catalog.builtins);
  let%bind result = within reply in
  assert (fst (Option.value_exn result) = 4);
  let waiting = Host.next host in
  Host.stop host;
  let%bind stopped = within waiting in
  assert (Option.is_none stopped);
  Host.submit host [ 5 ];
  assert (!calls = 2);
  let active_gate = Ivar.create () in
  let calls = ref 0 in
  let active = Host.For_testing.create ~load:(fun () -> incr calls; Ivar.read active_gate) in
  Host.submit active [ 1; 2 ];
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  Host.submit active [ 3 ];
  let waiting = Host.next active in
  Host.stop active;
  Ivar.fill_exn active_gate (Ok Catalog.builtins);
  let%bind result = within waiting in
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  assert (Option.is_none result && !calls = 1);
  print_endline "latest-only scheduling and shutdown passed";
  [%expect {| latest-only scheduling and shutdown passed |}];
  return ()
;;

let%expect_test "runtime startup and palette reload stay asynchronous while editing" =
  let gates = Queue.create () in
  let calls = ref 0 in
  let snippets = Host.For_testing.create ~load:(fun () ->
    incr calls;
    let gate = Ivar.create () in Queue.enqueue gates gate; Ivar.read gate) in
  let controller = Ches_app.Controller.create (Ches_core.Editor.create
    ~cell_width:Ches_screen.Cell_map.width Ches_core.Text_buffer.empty) in
  let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 160; height = 30 }
    (Ches_ui.Editor_view.app ~snippets controller ~exit:(fun () -> Effect.Ignore)) in
  let key key = Bonsai_term_test.send_event handle (Key_press { key; mods = [] }) in
  let type_text text = String.iter text ~f:(fun c -> key (ASCII c)) in
  let view () =
    Handle.recompute_view handle;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    [%expect.output] in
  let wait stage predicate =
    let last = ref "" in
    let rec loop () =
      last := view ();
      if predicate !last then return () else
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 2) in loop () in
    match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 5) (loop ()) with
    | `Result () -> ()
    | `Timeout -> failwith (stage ^ "\n" ^ !last) in
  let%bind () = wait "startup request" (fun _ -> !calls = 1) in
  type_text "iEDITING";
  assert (String.is_substring (view ()) ~substring:"EDITING");
  assert (!calls = 1);
  key Escape;
  Ivar.fill_exn (Queue.dequeue_exn gates) (Catalog.parse valid |> Result.map_error ~f:Error.to_string_hum);
  let%bind () = wait "startup reply" (fun output -> String.is_substring output ~substring:"Snippets reloaded") in
  type_text "A more";
  ignore (view () : string);
  key Escape;
  assert (!calls = 1);
  type_text " ccReload snippets"; key Enter;
  let%bind () = wait "palette reload request" (fun _ -> !calls = 2) in
  type_text "iAFTER";
  assert (String.is_substring (view ()) ~substring:"AFTER");
  assert (!calls = 2);
  key Escape;
  Ivar.fill_exn (Queue.dequeue_exn gates) (Error "fixture parse failure");
  let%bind () = wait "reload error reply" (fun output -> String.is_substring output ~substring:"fixture parse failure") in
  type_text "A zhost";
  assert (String.is_substring (view ()) ~substring:"[snippet]");
  key Enter;
  assert (String.is_substring (view ()) ~substring:"HOST_BODY");
  assert (!calls = 2);
  key Escape;
  type_text " Q";
  ignore (view () : string);
  Host.stop snippets;
  Ches_app.Controller.close controller;
  ignore ([%expect.output] : string);
  print_endline "startup, palette reload, failure and concurrent editing passed";
  [%expect {| startup, palette reload, failure and concurrent editing passed |}];
  return ()
;;
