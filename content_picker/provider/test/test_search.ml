open! Core
open! Async
open Ches_content_search
open Ches_content_picker
module Status = Model.Status
let fake = Filename_unix.realpath "fake_rg/fake_rg.exe"
let limits = { Provider.Limits.default with debounce = Time_ns.Span.zero }
let write root path data =
  let path = Filename.concat root path in
  Core_unix.mkdir_p (Filename.dirname path);
  Out_channel.write_all path ~data
;;
let rec remove path =
  match (Core_unix.lstat path).st_kind with
  | S_DIR -> Array.iter (Sys_unix.readdir path) ~f:(fun name -> remove (Filename.concat path name)); Core_unix.rmdir path
  | _ -> Core_unix.unlink path
;;
let with_root f =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-content" "") in
  Monitor.protect (fun () -> f root) ~finally:(fun () -> remove root; return ())
;;
let pause () = Clock_ns.after (Time_ns.Span.of_int_ms 1)
let timeout d =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_sec 10.) d with
  | `Result r -> r | `Timeout -> failwith "Search test timed out"
;;
let rec complete p =
  ignore (Provider.poll p ~max_batches:1 : Model.snapshot option);
  let snapshot = Option.value_exn (Provider.snapshot p) in
  match snapshot.status with
  | Loading | Partial -> let%bind () = pause () in complete p
  | _ -> return snapshot
;;
let run ?(prog = fake) ?(limits = limits) ?(query = "needle") root =
  let p = Provider.create ~prog ~limits () in
  let r = Provider.start p ~root ~query |> Or_error.ok_exn in
  let%bind snapshot = timeout (complete p) in
  let%map () = timeout (Provider.finished r) in snapshot
;;
let is_complete (s : Model.snapshot) ~truncated =
  assert (Status.equal_status s.status (Complete { truncated }))
;;
let assert_reaped root =
  let pid = In_channel.read_all (root ^ "/pid") |> Pid.of_string in
  match Core_unix.wait_nohang (`Pid pid) with
  | exception Core_unix.Unix_error (ECHILD, _, _) -> ()
  | _ -> failwith "search child was not reaped"
;;

let%expect_test "real rg literal case-sensitive ignore root raw paths and on-disk bytes" =
  with_root (fun root ->
    write root ".git/config" "a.b";
    write root ".gitignore" "ignored\n";
    write root ".ignore" "local\n";
    List.iter [ "ignored"; "local"; ".hidden"; ".secret/a" ] ~f:(fun p -> write root p "a.b");
    write root "other" "axb A.B\n";
    write root "sub/odd\n\255" "界\ta.b a.b\255\n";
    Core_unix.symlink ~target:(root ^ "/sub") ~link_name:(root ^ "/alias");
    let%bind s = run ~prog:"rg" ~query:"a.b" root in
    is_complete s ~truncated:false;
    [%test_eq: int] (List.length s.hits) 2;
    List.iter s.hits ~f:(fun hit ->
      assert (String.equal (Model.Candidate.path hit.candidate) (root ^ "/sub/odd\n\255"));
      assert (hit.line = 1 && String.equal hit.text "界\ta.b a.b\255\n"));
    [%test_eq: int list] (List.map s.hits ~f:(fun hit -> hit.start_byte)) [ 4; 8 ];
    let%bind empty = run ~prog:"rg" ~query:"no such literal" root in
    is_complete empty ~truncated:false; assert (List.is_empty empty.hits);
    let%map spaces = run ~prog:"rg" ~query:" " root in
    is_complete spaces ~truncated:false;
    assert (not (List.is_empty spaces.hits)))
;;

let%expect_test "empty query launches no process and validation leaves active run intact" =
  with_root (fun root ->
    let p = Provider.create ~prog:"/missing-rg" ~limits () in
    let r = Provider.start p ~root ~query:"" |> Or_error.ok_exn in
    let%bind s = timeout (complete p) in
    is_complete s ~truncated:false; assert (List.is_empty s.hits);
    assert (not (Sys_unix.file_exists_exn (root ^ "/pid")));
    List.iter [ "bad\nquery"; "bad\000query"; String.make 4097 'a' ] ~f:(fun query ->
      assert (Result.is_error (Provider.start p ~root ~query)));
    assert (Result.is_error (Provider.start p ~root:"relative" ~query:"needle"));
    assert (Model.same_request (Provider.request r) (Option.value_exn (Provider.snapshot p)).request);
    let%map () = Provider.finished r in ())
;;

let%expect_test "structured base64 fields multiple occurrences correct byte coordinates and argv" =
  with_root (fun root ->
    write root "mode" "normal";
    let%map s = run root in
    is_complete s ~truncated:false;
    [%test_eq: int list] (List.map s.hits ~f:(fun hit -> hit.start_byte)) [ 4; 11 ];
    List.iter s.hits ~f:(fun hit ->
      assert (hit.line = 3 && String.equal hit.text "界\tneedle needle\255\n");
      assert (String.equal (Model.Candidate.relative_path hit.candidate) "odd\n\255"));
    let args = In_channel.read_all (root ^ "/args") in
    List.iter [ "--json"; "--fixed-strings"; "--case-sensitive"; "--no-config"; "--\nneedle\n." ]
      ~f:(fun arg -> assert (String.is_substring args ~substring:arg));
    assert_reaped root)
;;

let%expect_test "actionable failures safe stderr malformed JSON and partial retention" =
  with_root (fun root ->
    let%bind missing = run ~prog:"/no-such-rg" root in
    (match missing.status with Failed message -> assert (String.is_substring message ~substring:"Install ripgrep") | _ -> assert false);
    let%bind bad_root = run (root ^ "/absent") in
    (match bad_root.status with Failed _ -> () | _ -> assert false);
    write root "mode" "failure";
    let%bind s = run root in
    assert (List.length s.hits = 2);
    (match s.status with Failed message ->
       assert (String.length message < 34_000 && not (String.exists message ~f:(fun c -> Char.to_int c < 32)))
     | _ -> assert false);
    assert_reaped root;
    Deferred.List.iter ~how:`Sequential [ "malformed"; "unterminated"; "invalid-offset"; "invalid-path" ]
      ~f:(fun mode -> write root "mode" mode; let%map s = run root in
        match s.status with Failed _ -> assert_reaped root | _ -> assert false))
;;

let%expect_test "all bounds are visible truncation and hidden metadata is rejected" =
  with_root (fun root ->
    let cases =
      [ "normal", { limits with max_hits = 1 }
      ; "normal", { limits with max_payload_bytes = 1 }
      ; "normal", { limits with max_text_bytes = 1 }
      ; "long", { limits with max_record_bytes = 100 }
      ; "long-path", limits
      ; "normal", { limits with max_output_bytes = 1 } ] in
    let%bind () = Deferred.List.iter ~how:`Sequential cases ~f:(fun (mode, limits) ->
      write root "mode" mode; let%map s = run ~limits root in
      is_complete s ~truncated:true; assert_reaped root) in
    write root "mode" "hidden";
    let%map s = run root in
    is_complete s ~truncated:false; assert (List.length s.hits = 2))
;;

let%expect_test "debounce cancellation stale query root rejection and once-only fake acceptance" =
  with_root (fun root ->
    write root "mode" "normal";
    let debounced = { limits with debounce = Time_ns.Span.of_int_ms 30 } in
    let p = Provider.create ~prog:fake ~limits:debounced () in
    let old = Provider.start p ~root ~query:"obsolete" |> Or_error.ok_exn in
    let latest = Provider.start p ~root ~query:"needle" |> Or_error.ok_exn in
    let%bind () = timeout (Provider.finished old) in
    assert (not (Sys_unix.file_exists_exn (root ^ "/pid")));
    let%bind s = timeout (complete p) in
    let%bind () = timeout (Provider.finished latest) in
    assert (Model.same_request s.request (Provider.request latest));
    let session = Model.create ~token:7 s in
    assert (not (Model.install session { s with request = Provider.request old }));
    assert (not (Model.install session { s with request = { s.request with root = "/other" } }));
    Model.update session Next;
    assert ((Option.value_exn (Model.selected session)).start_byte = 11);
    assert (Model.install session s);
    assert ((Option.value_exn (Model.selected session)).start_byte = 11);
    Model.update session (Paste "!");
    let calls = ref 0 and released = ref false in
    let release () = released := true in
    let consume (intent : int Model.intent) =
      assert (!released && Model.closed session && intent.token = 7);
      assert (String.equal intent.path (root ^ "/odd\n\255"));
      assert (intent.line = 3 && intent.byte_column = 11 && intent.end_byte = 17);
      incr calls;
      Model.accept session ~release ~consume:(fun _ -> assert false) in
    Model.accept session ~release ~consume; assert (!calls = 0);
    assert (not (Model.install session s));
    Model.update session Backspace;
    Model.accept session ~release ~consume;
    Model.accept session ~release ~consume;
    assert (!calls = 1);
    let cancelled = Model.create ~token:() s in
    Model.cancel cancelled ~release;
    Model.accept cancelled ~release ~consume:(fun _ -> assert false);
    return ())
;;

let%expect_test "cancel stalled child reaps before replacement and drops queued deliveries" =
  with_root (fun root ->
    write root "mode" "pushback";
    let p = Provider.create ~prog:fake ~limits:{ limits with batch_size = 1 } () in
    let old = Provider.start p ~root ~query:"needle" |> Or_error.ok_exn in
    let rec pid () = if Sys_unix.file_exists_exn (root ^ "/pid") then return () else let%bind () = pause () in pid () in
    let%bind () = timeout (pid ()) in
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 20) in
    Provider.cancel p;
    let%bind () = timeout (Provider.finished old) in
    assert_reaped root;
    write root "mode" "normal";
    let current = Provider.start p ~root ~query:"needle" |> Or_error.ok_exn in
    let%bind s = timeout (complete p) in
    let%map () = timeout (Provider.finished current) in
    is_complete s ~truncated:false;
    assert (List.length s.hits = 2 && Model.same_request s.request (Provider.request current));
    assert_reaped root)
;;

let%expect_test "timeout reaps even when host never polls blocked batches" =
  with_root (fun root ->
    write root "mode" "pushback";
    let p = Provider.create ~prog:fake ~limits:{ limits with batch_size = 1; timeout = Time_ns.Span.of_int_ms 50 } () in
    let r = Provider.start p ~root ~query:"needle" |> Or_error.ok_exn in
    let%bind () = timeout (Provider.finished r) in
    assert_reaped root;
    let%map s = timeout (complete p) in
    match s.status with Failed message -> assert (String.is_substring message ~substring:"timed out") | _ -> assert false)
;;

let%expect_test "refresh during spawning and root changes isolate results and session requests" =
  with_root (fun root -> with_root (fun other ->
    write root "mode" "pushback";
    write other "mode" "normal";
    let p = Provider.create ~prog:fake ~limits:{ limits with batch_size = 1 } () in
    let old = Provider.start p ~root ~query:"needle" |> Or_error.ok_exn in
    let%bind () = Scheduler.yield () in
    let current = Provider.start p ~root:other ~query:"needle" |> Or_error.ok_exn in
    let%bind s = timeout (complete p) in
    let%bind () = timeout (Provider.finished old) in
    let%bind () = timeout (Provider.finished current) in
    assert (List.length s.hits = 2);
    List.iter s.hits ~f:(fun h -> assert (String.equal (Model.Candidate.root h.candidate) other));
    let session = Model.create ~token:() s in
    let next_request = { s.request with run_id = Model.Run_id.of_int 100 } in
    Model.expect session next_request;
    assert (List.is_empty (Model.snapshot session).hits);
    assert (not (Model.install session s));
    let fresh = { s with request = next_request } in
    assert (Model.install session fresh);
    Model.update session Next;
    assert (Model.install session { fresh with hits = List.take fresh.hits 1 });
    assert ((Option.value_exn (Model.selected session)).start_byte = 4);
    assert (Model.install session { fresh with hits = [] });
    assert (Option.is_none (Model.selected session));
    Model.accept session ~release:(fun () -> assert false) ~consume:(fun _ -> assert false);
    Model.update session (Paste (String.concat (List.init 2000 ~f:(fun _ -> "界"))));
    assert (String.length (Model.query session) <= 4096);
    assert (Model.query_truncated session);
    assert (Stdlib.String.is_valid_utf_8 (Model.query session));
    Model.cancel session ~release:(fun () -> ());
    assert (not (Model.install session fresh));
    assert_reaped other;
    return ()))
;;
