open! Core
open! Async
open Ches_screen
module Runtime = Ches_content_picker_host.Runtime
module Model = Ches_content_picker.Model
module Provider = Ches_content_search.Provider
module Expect_test_config = Async.Expect_test_config
let width = 120
let height = 40
let fake_rg = Filename_unix.realpath "fake_rg/fake_rg.exe"
let ui () = Ui_state.create (Ches_app.Controller.create
  (Ches_core.Editor.create ~cell_width:Cell_map.width
    (Ches_core.Text_buffer.of_string "dirty independent text"
     |> Result.map_error ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum
     |> Result.ok_or_failwith)))
let apply ui inputs = fst (Ui_state.apply_all ui ~width ~height inputs)
let key ui key = apply ui [ Key key ]
let type_query ui text = apply ui (String.to_list text |> List.map ~f:(fun c -> Ui_state.Input.Key (Ches_input.Key.char c)))
let session ui = Content_picker_tile.session (Option.value_exn (Ui_state.content_picker ui))
let frame ui = Frame.to_string (Frame.render ui ~width ~height)
let open_picker runtime ui root = Runtime.open_picker runtime ui ~root ~width ~height |> Or_error.ok_exn
let timeout d =
  match%map Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) d with
  | `Result v -> v | `Timeout -> failwith "content host integration timed out"
let drain runtime state = timeout (Runtime.pump runtime ~current:(fun () -> !state)
  ~inject:(fun events -> state := apply !state events; return ()))
let with_root mode f =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-content-host" "") in
  Out_channel.write_all (root ^ "/mode") ~data:mode;
  Monitor.protect (fun () -> f root) ~finally:(fun () ->
    Array.iter (Sys_unix.readdir root) ~f:(fun p -> Core_unix.unlink (root ^ "/" ^ p));
    Core_unix.rmdir root; return ())
let limits = { Provider.Limits.default with batch_size = 1; debounce = Time_ns.Span.zero }

let%expect_test "provider-host: bounded batches, byte intent, empty/pending Enter and release" =
  with_root "normal" (fun root ->
    let runtime = Runtime.create ~prog:fake_rg ~limits () in
    let initial = ui () in
    let state = ref (open_picker runtime initial root) in
    let%bind () = drain runtime state in
    assert (not (Sys_unix.file_exists_exn (root ^ "/pid")));
    state := key !state Enter;
    assert (Option.is_some (Ui_state.content_picker !state));
    state := type_query !state "needle";
    state := key !state Enter;
    assert (Model.pending (session !state));
    let max_added = ref 0 and previous = ref 0 in
    let%bind () = timeout (Runtime.pump runtime ~current:(fun () -> !state)
      ~inject:(fun events ->
        state := apply !state events;
        let n = List.length (Model.snapshot (session !state)).hits in
        max_added := Int.max !max_added (n - !previous); previous := n; return ())) in
    assert (!max_added = 1 && !previous = 2);
    state := key !state (Ches_input.Key.Ctrl 'n');
    let selected = Option.value_exn (Model.selected (session !state)) in
    assert (selected.start_byte = 11);
    let old = session !state in
    state := key !state Enter;
    assert (Model.closed old && Option.is_none (Ui_state.content_picker !state));
    assert (Ches_tile.View_id.equal (Ui_state.focused_view !state ~width ~height) Ui_state.document_id);
    let next, intents = Ui_state.take_content_requests !state in state := next;
    let intent = List.hd_exn intents in
    assert (List.length intents = 1 && intent.byte_column = 11 && intent.line = 3);
    assert (String.equal intent.path (root ^ "/odd\n\255"));
    assert (String.equal intent.expected_text "界\tneedle needle\255\n" && String.equal intent.literal "needle");
    assert (List.is_empty (snd (Ui_state.take_content_requests !state)));
    assert (String.equal (frame initial) (frame !state));
    timeout (Runtime.finished runtime))
;;

let%expect_test "provider errors, missing rg, empty results and caps surface in shared frames" =
  Deferred.List.iter ~how:`Sequential [ "failure"; "normal"; "empty"; "missing" ] ~f:(fun mode ->
    with_root mode (fun root ->
      let runtime = Runtime.create ~prog:(if String.equal mode "missing" then "/no/such/rg" else fake_rg)
        ~limits:{ limits with max_hits = (if String.equal mode "normal" then 1 else 10) } () in
      let state = ref (type_query (open_picker runtime (ui ()) root) "needle") in
      let%bind () = drain runtime state in
      let expected = match mode with "normal" -> "TRUNCATED"
        | "missing" | "failure" -> "Search failed" | _ -> "No on-disk matches" in
      assert (String.is_substring (frame !state) ~substring:expected);
      state := key !state Escape;
      timeout (Runtime.finished runtime)))
;;

let%expect_test "interrupted provider and paste: stale queries/reopens, resize, cancellation and ECHILD" =
  with_root "pushback" (fun root ->
    let runtime = Runtime.create ~prog:fake_rg ~limits () in
    let initial = ui () in
    let state = ref (type_query (open_picker runtime initial root) "needle") in
    let%bind events = Runtime.next runtime !state in state := apply !state events;
    let old_request = (Model.snapshot (session !state)).request in
    let rec spawned () =
      if Sys_unix.file_exists_exn (root ^ "/pid") then return ()
      else let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in spawned () in
    let%bind () = timeout (spawned ()) in
    let pid = Pid.of_string (In_channel.read_all (root ^ "/pid")) in
    let queued = Runtime.next runtime !state in
    state := type_query !state "x";
    let%bind events = queued in assert (List.is_empty events);
    state := apply !state [ Content_picker_snapshot
      { request = old_request; hits = []; status = Failed "OLD ERROR" } ];
    assert (not (String.is_substring (frame !state) ~substring:"OLD ERROR"));
    state := apply !state [ Paste_start; Key (Ches_input.Key.char 'O') ];
    assert (Result.is_error (Runtime.open_picker runtime !state ~root ~width ~height));
    state := fst (Ui_state.apply_all !state ~width:13 ~height:5 [ Resize ]);
    let%bind () = timeout (Runtime.finished runtime) in
    (match Core_unix.wait_nohang (`Pid pid) with
     | exception Core_unix.Unix_error (ECHILD, _, _) -> ()
     | _ -> failwith "content child not reaped");
    state := apply !state [ Key (Ches_input.Key.char 'L'); Paste_end ];
    assert (Option.is_none (Ui_state.content_picker !state));
    Out_channel.write_all (root ^ "/mode") ~data:"normal";
    state := type_query (open_picker runtime !state root) "needle";
    let replacement = session !state in
    let queued = Runtime.next runtime !state in
    state := key !state Escape;
    state := type_query (open_picker runtime !state root) "needle";
    let%bind events = queued in
    assert (List.is_empty events && Model.closed replacement);
    let%bind () = drain runtime state in
    assert (List.length (Model.snapshot (session !state)).hits = 2);
    state := key !state Escape;
    assert (String.equal (Ches_core.Text_buffer.to_string
      (Ches_core.Editor.text (Ches_app.Controller.editor (Ui_state.controller !state)))) "dirty independent text");
    timeout (Runtime.finished runtime))
;;

let%expect_test "debounced query cancellation prevents spawn, query replacement starts fresh" =
  with_root "normal" (fun root ->
    let runtime = Runtime.create ~prog:fake_rg
      ~limits:{ limits with debounce = Time_ns.Span.of_int_ms 100 } () in
    let state = ref (type_query (open_picker runtime (ui ()) root) "need") in
    let%bind events = Runtime.next runtime !state in state := apply !state events;
    state := type_query !state "le";
    let%bind () = drain runtime state in
    assert (String.equal (Model.snapshot (session !state)).request.query "needle");
    let args = In_channel.read_all (root ^ "/args") in
    assert (String.is_substring args ~substring:"needle");
    state := key !state Escape;
    let%bind () = timeout (Runtime.finished runtime) in
    Core_unix.unlink (root ^ "/pid");
    state := type_query (open_picker runtime !state root) "needle";
    let%bind _ = Runtime.next runtime !state in
    state := key !state Escape;
    let%map () = timeout (Runtime.finished runtime) in
    assert (not (Sys_unix.file_exists_exn (root ^ "/pid"))))
;;

let%expect_test "query replacement reaps an already spawned child; stalled search timeout is visible" =
  with_root "stall" (fun root ->
    let runtime = Runtime.create ~prog:fake_rg ~limits () in
    let state = ref (type_query (open_picker runtime (ui ()) root) "needle") in
    let%bind events = Runtime.next runtime !state in state := apply !state events;
    let rec pid () =
      if Sys_unix.file_exists_exn (root ^ "/pid") then
        return (Pid.of_string (In_channel.read_all (root ^ "/pid")))
      else let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in pid () in
    let%bind old_pid = timeout (pid ()) in
    state := type_query !state "x";
    let%bind events = Runtime.next runtime !state in state := apply !state events;
    let rec replaced () =
      let%bind new_pid = pid () in
      if Pid.equal old_pid new_pid then
        let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in replaced ()
      else return () in
    let%bind () = timeout (replaced ()) in
    (match Core_unix.wait_nohang (`Pid old_pid) with
     | exception Core_unix.Unix_error (ECHILD, _, _) -> ()
     | _ -> failwith "replaced-query child not reaped");
    assert (String.equal (Model.snapshot (session !state)).request.query "needlex");
    state := key !state Escape;
    let%bind () = timeout (Runtime.finished runtime) in
    let runtime = Runtime.create ~prog:fake_rg
      ~limits:{ limits with timeout = Time_ns.Span.of_int_ms 30 } () in
    state := type_query (open_picker runtime !state root) "needle";
    let%bind () = drain runtime state in
    assert (String.is_substring (frame !state) ~substring:"Search failed");
    state := key !state Escape;
    timeout (Runtime.finished runtime))
;;
