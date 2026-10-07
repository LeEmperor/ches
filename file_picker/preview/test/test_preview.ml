open! Core
open! Async
open Ches_file_preview
module Picker = Ches_file_picker.Model
let session n : Picker.Discovery.request = { run_id = Picker.Run_id.of_int n; root = "/tmp/opencode" }
let candidate name = Picker.Candidate.create ~root:"/tmp/opencode" ~relative_path:name |> Or_error.ok_exn
let payload = function Model.Ready p | Truncated (p, _) -> p | _ -> failwith "Expected preview text"
let collect text =
  let pos = ref 0 in
  let result = Model.collect ~source:Disk ~cancelled:(fun () -> false)
    ~read:(fun buf ~len ->
      let n = Int.min len (String.length text - !pos) in
      Stdlib.Bytes.blit_string text !pos buf 0 n;
      pos := !pos + n; n) |> Option.value_exn in
  result, !pos
;;
let%test_unit "byte AND line budgets enforced in reads, no long-line materialization" =
  let state, consumed = collect (String.make (2 * Model.max_bytes) 'x') in
  assert (consumed = Model.max_bytes);
  assert (String.length (payload state).text = Model.max_bytes);
  (match state with Truncated (_, { bytes = true; lines = false; _ }) -> () | _ -> assert false);
  let state, consumed = collect (String.make 1_000_000 '\n') in
  assert (consumed = 100 && List.length (payload state).lines = 100);
  (match state with Truncated (_, { lines = true; _ }) -> () | _ -> assert false);
  let text = String.concat (List.init 150 ~f:(fun _ -> "some text\n")) in
  let state, consumed = collect text in
  assert (consumed = 1000 && List.length (payload state).lines = 100)
;;
let%test_unit "UTF8 cap drops only incomplete legal final scalar; EOF invalid is unsupported" =
  List.iter [ "\xc2"; "\xe7\x95"; "\xf0\x9f\x98" ] ~f:(fun tail ->
    let prefix = String.make (Model.max_bytes - String.length tail) 'a' in
    let state, consumed = collect (prefix ^ tail ^ "\x80more") in
    assert (consumed = Model.max_bytes && String.equal (payload state).text prefix);
    match state with Truncated (_, { utf8_boundary = true; _ }) -> () | _ -> assert false);
  List.iter [ "\xff"; "\xe0\x80"; "\xed\xa0"; "\xf4\x90" ] ~f:(fun tail ->
    let state, _ = collect (String.make (Model.max_bytes - String.length tail) 'a' ^ tail) in
    match state with Unsupported Encoding -> () | _ -> assert false);
  (match fst (collect "abc\xe7\x95") with Unsupported Encoding -> () | _ -> assert false);
  (match fst (collect "abc\000binary") with Unsupported Binary -> () | _ -> assert false);
  (match fst (collect "") with Empty Disk -> () | _ -> assert false);
  assert (Option.is_none (Model.collect ~source:Disk ~cancelled:(fun () -> true)
    ~read:(fun _ ~len:_ -> failwith "Cancelled collector performed IO")));
  let stopped = ref false and reads = ref 0 in
  assert (Option.is_none (Model.collect ~source:Disk ~cancelled:(fun () -> !stopped)
    ~read:(fun buf ~len -> incr reads; stopped := true; Bytes.fill buf ~pos:0 ~len 'a'; len)));
  assert (!reads = 1)
;;
let%test_unit "bounded immutable buffer copy: giant line, line cap, UTF8 boundary" =
  let text s = Ches_core.Text_buffer.of_string s |> Result.ok |> Option.value_exn in
  let state = Model.of_buffer ~revision:42 (text (String.make 1_000_000 'a')) in
  assert (String.length (payload state).text = Model.max_bytes);
  assert (Model.equal_source (payload state).source (Buffer { revision = 42 }));
  let state = Model.of_buffer ~revision:43 (text (String.make 1_000_000 '\n')) in
  assert (String.length (payload state).text = 100 && List.length (payload state).lines = 100);
  let state = Model.of_buffer ~revision:44 (text (String.make (Model.max_bytes - 1) 'a' ^ "界more")) in
  assert (String.length (payload state).text = Model.max_bytes - 1);
  match state with Truncated (_, { utf8_boundary = true; _ }) -> () | _ -> assert false
;;
let pause () = Clock_ns.after (Time_ns.Span.of_int_ms 1)
let timeout d =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_sec 5.) d with
  | `Result r -> r | `Timeout -> failwith "Preview test timed out"
;;
let rec terminal p =
  match Provider.snapshot p with
  | Some { state = Loading; _ } -> let%bind () = Provider.changed p in terminal p
  | Some s -> return s
  | None -> failwith "Preview disappeared"
;;
let%expect_test "single active read/latest pending, stale A-B-A, sessions, clear, queued installation" =
  let calls = ref [] in
  let p = Provider.For_testing.create ~debounce:Time_ns.Span.zero
    ~buffer:(fun ~path:_ -> None)
    ~read:(fun ~cancelled ~path ->
      let result = Ivar.create () in
      calls := !calls @ [ path, cancelled, result ]; Ivar.read result) () in
  let a = Provider.select p ~session:(session 1) (candidate "a") in
  let%bind () = pause () in
  assert (List.length !calls = 1);
  let _, cancelled, first = List.hd_exn !calls in
  let old_delivery : Model.snapshot = { request = a; state = Missing } in
  for i = 1 to 1000 do
    ignore (Provider.select p ~session:(session 1) (candidate (Int.to_string i)) : Model.request)
  done;
  let latest = Provider.select p ~session:(session 1) (candidate "a") in
  assert (not (Model.equal_request a latest));
  assert (not (Model.accept ~expected:(Some latest) old_delivery));
  let%bind () = pause () in
  assert (List.length !calls = 1 && Atomic.get cancelled);
  Ivar.fill_exn first (Some (fst (collect "obsolete")));
  let%bind () = pause () in
  assert (List.length !calls = 2);
  assert (match (Option.value_exn (Provider.snapshot p)).state with Loading -> true | _ -> false);
  let _, cancelled2, second = List.nth_exn !calls 1 in
  let reopened = Provider.select p ~session:(session 2) (candidate "a") in
  assert (not (Model.accept ~expected:(Some reopened) { old_delivery with request = latest }));
  Provider.clear p;
  assert (Option.is_none (Provider.snapshot p) && Atomic.get cancelled2);
  assert (not (Model.accept ~expected:None old_delivery));
  Ivar.fill_exn second (Some (fst (collect "late")));
  let%bind () = timeout (Provider.finished p) in
  let%map () = pause () in
  assert (Option.is_none (Provider.snapshot p) && List.length !calls = 2)
;;
let%expect_test "debounce coalesces and snapshots current buffer only at launch; same identity idempotent" =
  let current = ref (fst (collect "old")) and calls = ref 0 and reads = ref 0 in
  let p = Provider.For_testing.create ~debounce:(Time_ns.Span.of_int_ms 20)
    ~buffer:(fun ~path:_ -> incr calls; Some !current)
    ~read:(fun ~cancelled:_ ~path:_ -> incr reads; return None) () in
  for i = 1 to 100 do
    ignore (Provider.select p ~session:(session 1) (candidate (Int.to_string i)) : Model.request)
  done;
  let request = Provider.select p ~session:(session 1) (candidate "final") in
  assert (Model.equal_request request (Provider.select p ~session:(session 1) (candidate "final")));
  current := fst (collect "new unsaved");
  let%bind s = timeout (terminal p) in
  assert (!calls = 1 && !reads = 0 && String.equal (payload s.state).text "new unsaved");
  ignore (Provider.select p ~session:(session 1) (candidate "never") : Model.request);
  Provider.clear p;
  let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 30) in
  assert (!calls = 1 && Option.is_none (Provider.snapshot p))
;;
let%expect_test "timeout releases visible state but does not spawn concurrent stalled reads" =
  let first = Ivar.create () and calls = ref 0 in
  let p = Provider.For_testing.create ~debounce:Time_ns.Span.zero
    ~timeout:(Time_ns.Span.of_int_ms 10) ~buffer:(fun ~path:_ -> None)
    ~read:(fun ~cancelled:_ ~path:_ -> incr calls; if !calls = 1 then Ivar.read first else return (Some Model.Missing)) () in
  ignore (Provider.select p ~session:(session 1) (candidate "stalled") : Model.request);
  let%bind s = timeout (terminal p) in
  (match s.state with Unreadable _ -> () | _ -> assert false);
  ignore (Provider.select p ~session:(session 1) (candidate "next") : Model.request);
  let%bind () = pause () in
  assert (!calls = 1);
  Ivar.fill_exn first None;
  let%bind s = timeout (terminal p) in
  assert (!calls = 2);
  (match s.state with Missing -> () | _ -> assert false);
  Provider.clear p;
  return ()
;;
let%expect_test "host follow seam consumes actual picker selection/empty/close; refresh guards dirty revisions" =
  let current = ref (fst (collect "revision one")) in
  let p = Provider.create ~debounce:Time_ns.Span.zero ~buffer:(fun ~path:_ -> Some !current) () in
  let discovery : Picker.Discovery.t =
    { request = session 9; candidates = [ candidate "a"; candidate "b" ]; status = Complete { truncated = false } } in
  let model = Picker.create ~token:42 ~discovery in
  let results = List.map discovery.candidates ~f:(fun candidate ->
    ({ candidate; score = 0; positions = [] } : Picker.Query_result.t)) in
  let model = Picker.with_results model ~query:"" results in
  let a = Provider.follow p (Some model) |> Option.value_exn in
  let%bind s = timeout (terminal p) in
  assert (Model.accept ~expected:(Some a) s);
  let model = Picker.select model (Picker.Candidate.id (candidate "b")) in
  let b = Provider.follow p (Some model) |> Option.value_exn in
  assert (not (Model.accept ~expected:(Some b) s));
  let%bind old_b = timeout (terminal p) in
  current := fst (collect "revision two");
  let refreshed = Provider.follow ~refresh:true p (Some model) |> Option.value_exn in
  assert (not (Model.accept ~expected:(Some refreshed) old_b));
  let%bind s = timeout (terminal p) in
  assert (String.equal (payload s.state).text "revision two");
  let empty = Picker.with_results model ~query:"none" [] in
  assert (Option.is_none (Provider.follow p (Some empty)) && Option.is_none (Provider.snapshot p));
  ignore (Provider.follow p (Some model) : Model.request option);
  assert (Option.is_none (Provider.follow p None));
  let%map () = pause () in assert (Option.is_none (Provider.snapshot p))
;;
let%expect_test "teardown wakes idle waiter; lookup/read exceptions become explicit bounded errors" =
  let p = Provider.For_testing.create ~debounce:Time_ns.Span.zero
    ~buffer:(fun ~path -> if String.is_suffix path ~suffix:"buffer-error" then failwith "buffer failure" else None)
    ~read:(fun ~cancelled:_ ~path:_ -> failwith "read failure") () in
  let waiting = Provider.changed p in
  Provider.clear p;
  let%bind () = timeout waiting in
  let%bind () = Deferred.List.iter ~how:`Sequential [ "buffer-error"; "read-error" ] ~f:(fun name ->
    ignore (Provider.select p ~session:(session 1) (candidate name) : Model.request);
    let%map s = timeout (terminal p) in match s.state with Unreadable _ -> () | _ -> assert false) in
  Provider.clear p;
  timeout (Provider.finished p)
;;
let with_root f =
  let root = Core_unix.mkdtemp "/tmp/opencode/ches-preview-" in
  Monitor.protect (fun () -> f root) ~finally:(fun () ->
    Array.iter (Sys_unix.readdir root) ~f:(fun name -> Core_unix.unlink (Filename.concat root name));
    Core_unix.rmdir root; return ())
;;
let at root name = Picker.Candidate.create ~root ~relative_path:name |> Or_error.ok_exn
let%expect_test "real disk prefix, missing/binary/empty/FIFO/directory and symlink policies" =
  with_root (fun root ->
    Out_channel.write_all (root ^ "/large") ~data:(String.make 1_000_000 'x');
    Out_channel.write_all (root ^ "/empty") ~data:"";
    Out_channel.write_all (root ^ "/binary") ~data:"\000\001";
    Core_unix.mkfifo (root ^ "/fifo") ~perm:0o600;
    Core_unix.symlink ~target:(root ^ "/large") ~link_name:(root ^ "/link");
    Core_unix.symlink ~target:(root ^ "/fifo") ~link_name:(root ^ "/fifo-link");
    Core_unix.symlink ~target:root ~link_name:(root ^ "/dir-link");
    Core_unix.symlink ~target:(root ^ "/missing") ~link_name:(root ^ "/broken");
    Core_unix.symlink ~target:(root ^ "/loop") ~link_name:(root ^ "/loop");
    let p = Provider.create ~debounce:Time_ns.Span.zero ~buffer:(fun ~path:_ -> None) () in
    let run name = ignore (Provider.select p ~session:(session 1) (at root name) : Model.request); timeout (terminal p) in
    let%bind large = run "large" in
    assert ((payload large.state).bytes_read = Model.max_bytes);
    let%bind link = run "link" in assert ((payload link.state).bytes_read = Model.max_bytes);
    let%bind () = Deferred.List.iter ~how:`Sequential [ "fifo"; "fifo-link"; "dir-link" ] ~f:(fun name ->
      let%map s = run name in match s.state with Unsupported Special_file -> () | _ -> assert false) in
    let%bind () = Deferred.List.iter ~how:`Sequential [ "missing"; "broken" ] ~f:(fun name ->
      let%map s = run name in match s.state with Missing -> () | _ -> assert false) in
    let%bind empty = run "empty" in (match empty.state with Empty Disk -> () | _ -> assert false);
    let%bind binary = run "binary" in (match binary.state with Unsupported Binary -> () | _ -> assert false);
    let%bind unavailable = run "loop" in (match unavailable.state with Unreadable _ -> () | _ -> assert false);
    Provider.clear p;
    timeout (Provider.finished p))
;;
let%expect_test "retained dirty missing buffer wins disk without activation or parsing; late lookup" =
  with_root (fun root ->
    let module App = Ches_app in
    let path = root ^ "/dirty.ml" in
    Out_channel.write_all path ~data:"disk\n";
    let controller = App.Controller.open_file ~cell_width:(fun _ -> 1) path |> Or_error.ok_exn in
    let app_session = App.Session.create ~cell_width:(fun _ -> 1) controller in
    let current = ref app_session in
    let p = Provider.create ~debounce:(Time_ns.Span.of_int_ms 10)
      ~buffer:(fun ~path -> Buffer_snapshot.lookup !current ~path) () in
    ignore (Provider.select p ~session:(session 1) (at root "dirty.ml") : Model.request);
    let dirty = Ches_core.Text_buffer.of_string ("unsaved\n" ^ String.make 1_000_000 'a') |> Result.ok |> Option.value_exn in
    let controller = App.Controller.rebase_text controller
      ~saved:(Ches_core.Editor.text (App.Controller.editor controller)) ~text:dirty in
    current := App.Session.replace_active !current controller;
    assert (Ches_core.Editor.is_dirty (App.Controller.editor controller));
    let parses = App.Controller.highlight_parse_count controller in
    let active = App.Session.active_id !current in
    Core_unix.unlink path;
    let%bind s = timeout (terminal p) in
    assert (String.is_prefix (payload s.state).text ~prefix:"unsaved\n");
    assert (String.length (payload s.state).text = Model.max_bytes);
    (match (payload s.state).source with Buffer _ -> () | _ -> assert false);
    assert (Option.equal App.Buffer_id.equal active (App.Session.active_id !current));
    assert (List.length (App.Session.buffers !current) = 1);
    assert (App.Controller.highlight_parse_count controller = parses);
    Provider.clear p; App.Session.dispose !current;
    return ())
;;
