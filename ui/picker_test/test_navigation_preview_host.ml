open! Core
open! Async
module Host = Ches_ui.Navigation_preview_host
module Model = Ches_navigation_preview_model.Model
module Q = Ches_error.Language_query
module Expect_test_config = Async.Expect_test_config

let request ?(line = 0) generation path : Model.request =
  let position : Q.position = { line; character = 0 } in
  let range : Q.range = { start = position; stop = position } in
  { generation; target = { path; range; selection = range; encoding = Utf8 } }
let turn () = Clock_ns.after (Time_ns.Span.of_int_ms 10)
let state host = (Option.value_exn (Host.snapshot host)).state

let%expect_test "A-B-A cancels, coalesces, and does not request on every follow" =
  let calls = ref [] in
  let read ~cancelled request =
    let result = Ivar.create () in calls := !calls @ [request, cancelled, result]; Ivar.read result in
  let host = Host.For_testing.create ~debounce:Time_ns.Span.zero
    ~buffer:(fun _ -> None) ~read () in
  let a = request 1 "/a" and b = request 2 "/b" and a2 = request 3 "/a" in
  Host.follow host (Some a);
  let%bind () = turn () in
  assert (List.length !calls = 1);
  let _, cancelled, first = List.hd_exn !calls in
  Host.follow host (Some b); Host.follow host (Some a2);
  let%bind () = turn () in
  assert (Atomic.get cancelled && List.length !calls = 1);
  Ivar.fill_exn first (Unreadable "obsolete");
  let%bind () = turn () in
  assert (List.length !calls = 2);
  let req, _, last = List.last_exn !calls in
  assert (req.generation = 3);
  Ivar.fill_exn last Missing;
  let%bind () = turn () in
  assert (match state host with Missing -> true | _ -> false);
  for _ = 1 to 100 do Host.follow host (Some a2) done;
  let%bind () = turn () in
  assert (List.length !calls = 2);
  Host.stop host;
  assert (Option.is_none (Host.snapshot host));
  print_endline "latest generation only; one physical read; stable follows";
  [%expect {| latest generation only; one physical read; stable follows |}]; return ()

let%expect_test "timeout delivers while disk remains occupied; retained results win" =
  let calls = ref 0 and lookup = ref None in
  let blocked = Ivar.create () in
  let host = Host.For_testing.create ~debounce:Time_ns.Span.zero
    ~timeout:(Time_ns.Span.of_int_ms 10)
    ~buffer:(fun _ -> !lookup)
    ~read:(fun ~cancelled:_ _ -> incr calls; Ivar.read blocked) () in
  Host.follow host (Some (request 1 "/a"));
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 30) in
  assert (match state host with Unreadable _ -> true | _ -> false);
  Host.follow host (Some (request 2 "/b"));
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 30) in
  assert (!calls = 1);
  assert (match state host with Unreadable _ -> true | _ -> false);
  lookup := Some (Invalid_target "retained invalid");
  Host.follow host (Some (request 3 "/c"));
  let%bind () = turn () in
  assert (match state host with Invalid_target _ -> true | _ -> false);
  assert (!calls = 1);
  Host.stop host;
  Ivar.fill_exn blocked Missing;
  let%bind () = Host.finished host in
  assert (Option.is_none (Host.snapshot host));
  print_endline "bounded timeout delivery and authoritative late retained lookup";
  [%expect {| bounded timeout delivery and authoritative late retained lookup |}]; return ()

let%expect_test "disk windows reach far lines and bound giant lines, scans, and special files" =
  let root = Filename_unix.temp_dir "ches-navigation-host" "" in
  let path = root ^ "/source" and fifo = root ^ "/fifo" and loop = root ^ "/loop" in
  let read ?(line = 0) path = Host.For_testing.disk_read
    ~cancelled:(Atomic.make false) (request ~line 1 path) in
  let%bind () = Monitor.protect (fun () ->
    Out_channel.write_all path ~data:(String.concat ~sep:"\n"
      (List.init 10000 ~f:(fun i -> sprintf "line_%d" i)));
    let%bind far = read ~line:9000 path in
    (match far with
     | Ready payload ->
       assert (payload.first_line <= 9000);
       assert (List.exists payload.lines ~f:(fun line -> String.equal line.text "line_9000"));
       assert (List.length payload.lines <= Model.max_lines)
     | _ -> failwith "far target missing");
    Out_channel.write_all path ~data:(String.make (Model.max_scan_bytes + 100) 'x');
    let%bind capped = read path in
    (match capped with
     | Ready payload ->
       assert payload.truncated;
       assert (List.for_all payload.lines ~f:(fun l -> String.length l.text <= Model.max_line_bytes));
       assert (List.sum (module Int) payload.lines ~f:(fun l -> String.length l.text) <= Model.max_output_bytes)
     | Limit _ -> () | _ -> failwith "expected bounded giant line");
    let%bind unreachable = read ~line:900000 path in
    assert (match unreachable with Limit _ -> true | _ -> false);
    let%bind missing = read (root ^ "/missing") in
    assert (match missing with Missing -> true | _ -> false);
    Core_unix.symlink ~target:loop ~link_name:loop;
    let%bind unreadable = read loop in
    assert (match unreadable with Unreadable _ -> true | _ -> false);
    Core_unix.mkfifo fifo ~perm:0o600;
    let%bind special = read fifo in
    assert (match special with Unsupported _ -> true | _ -> false);
    let%bind directory = read root in
    assert (match directory with Unsupported _ -> true | _ -> false);
    let%bind device = read "/dev/null" in
    assert (match device with Unsupported _ -> true | _ -> false);
    let%bind cancelled = Host.For_testing.disk_read ~cancelled:(Atomic.make true) (request 1 path) in
    assert (match cancelled with Cancelled -> true | _ -> false);
    return ())
    ~finally:(fun () -> Core_unix.unlink path; Core_unix.unlink fifo; Core_unix.unlink loop; Core_unix.rmdir root; return ()) in
  print_endline "far target, bounded lines/output/scan, missing/read errors, FIFO/directory/device and cancellation";
  [%expect {| far target, bounded lines/output/scan, missing/read errors, FIFO/directory/device and cancellation |}]; return ()
