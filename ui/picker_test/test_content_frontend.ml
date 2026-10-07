open! Core
open! Async
open Bonsai_test
open Bonsai_term
open Ches_screen
module Runtime = Ches_content_picker_host.Runtime
module Model = Ches_content_picker.Model
module Expect_test_config = Async.Expect_test_config

let%expect_test "content frontend deactivation closes session and rejects late snapshots and acceptance" =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-content-lifecycle" "") in
  Out_channel.write_all (root ^ "/file.ml") ~data:"needle\n";
  let runtime = Runtime.create () in
  let controller = Ches_app.Controller.create
    (Ches_core.Editor.create ~cell_width:Cell_map.width Ches_core.Text_buffer.empty) in
  let opened = Runtime.open_picker runtime (Ui_state.create controller)
    ~root ~width:80 ~height:24 |> Or_error.ok_exn in
  let session = Content_picker_tile.session (Option.value_exn (Ui_state.content_picker opened)) in
  let consumed = ref 0 in
  let content_picker : Ches_ui.Editor_view.Content_picker_host.t =
    { initial_ui = opened; runtime; consume = (fun _ -> incr consumed) } in
  let active = Bonsai.Expert.Var.create true in
  let component ~dimensions (local_ graph) =
    let open Bonsai.Let_syntax in
    let both = match%sub Bonsai.Expert.Var.value active with
      | false -> Bonsai.return (View.none, (fun _ -> Effect.Ignore))
      | true ->
        let ~view, ~handler = Ches_ui.Editor_view.app ~content_picker controller
          ~exit:(fun () -> Effect.Ignore) ~dimensions graph in
        let%arr view and handler in view, handler in
    let view = let%arr both in fst both in
    let handler = let%arr both in snd both in
    ~view, ~handler in
  let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 80; height = 24 } component in
  Handle.recompute_view handle;
  String.iter "needle" ~f:(fun c ->
    Bonsai_term_test.send_event handle (Key_press { key = ASCII c; mods = [] }));
  Handle.recompute_view handle;
  let snapshot = Model.snapshot session in
  Bonsai.Expert.Var.set active false;
  Handle.recompute_view handle;
  assert (Model.closed session);
  assert (List.is_empty (Model.snapshot session).hits);
  assert (not (Model.install session snapshot));
  Model.accept session ~release:(fun () -> failwith "late release") ~consume:(fun _ -> incr consumed);
  let%bind () = Runtime.finished runtime in
  let%bind () = Scheduler.yield () in
  Handle.recompute_view handle;
  assert (!consumed = 0 && Model.closed session);
  Core_unix.unlink (root ^ "/file.ml"); Core_unix.rmdir root;
  Ches_app.Controller.close controller;
  ignore ([%expect.output] : string);
  print_endline "content deactivation drops pending search and late delivery";
  [%expect {| content deactivation drops pending search and late delivery |}];
  return ()
;;

let%expect_test "real rg content frontend: scheduling, edits, raw byte intent and released cursor" =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-content-ui" "") in
  List.iter (List.init 300 ~f:(fun n -> sprintf "file%03d.ml" n)) ~f:(fun p ->
    Out_channel.write_all (root ^ "/" ^ p) ~data:"界\tneedle needle\n");
  let runtime = Runtime.create
    ~limits:{ Ches_content_search.Provider.Limits.default with batch_size = 2
      ; debounce = Time_ns.Span.of_int_ms 10 } () in
  let%bind () = Monitor.protect (fun () ->
    let text = Ches_core.Text_buffer.of_string "unsaved needle NOT searched" |> Result.map_error
      ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
    let controller = Ches_app.Controller.create (Ches_core.Editor.create ~cell_width:Cell_map.width text) in
    let opened = Runtime.open_picker runtime (Ui_state.create ~tiles_visible:false controller)
      ~root ~width:100 ~height:24 |> Or_error.ok_exn in
    let session = Content_picker_tile.session (Option.value_exn (Ui_state.content_picker opened)) in
    let consumed = ref [] in
    let content_picker : Ches_ui.Editor_view.Content_picker_host.t =
      { initial_ui = opened; runtime
      ; consume = (fun intent -> assert (Model.closed session); consumed := intent :: !consumed) } in
    let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 100; height = 24 }
      (Ches_ui.Editor_view.app ~content_picker controller ~exit:(fun () -> Effect.Ignore)) in
    let rec settle () =
      Handle.recompute_view handle;
      if Model.pending session || (match (Model.snapshot session).status with Loading | Partial -> true | _ -> false)
      then let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in settle ()
      else return () in
    let settle () =
      let%map result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (settle ()) in
      assert (match result with `Result () -> true | `Timeout -> false) in
    let send key = Bonsai_term_test.send_event handle (Key_press { key; mods = [] }) in
    let%bind () = settle () in
    send Enter;
    assert (not (Model.closed session));
    List.iter (String.to_list "needle") ~f:(fun c -> send (ASCII c));
    send Enter; (* old/empty results cannot be accepted while a query is pending *)
    assert (List.is_empty !consumed);
    let%bind () = settle () in
    assert (List.length (Model.snapshot session).hits = 600);
    assert (List.for_all (Model.snapshot session).hits ~f:(fun hit -> hit.start_byte = 4 || hit.start_byte = 11));
    send (ASCII 'x');
    let%bind () = settle () in
    assert (List.is_empty (Model.snapshot session).hits);
    send Enter;
    assert (not (Model.closed session));
    send Backspace;
    let%bind () = settle () in
    assert (List.length (Model.snapshot session).hits = 600);
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    let output = [%expect.output] in
    assert (String.is_substring output ~substring:"ON DISK");
    assert (String.is_substring output ~substring:"(kind Bar)");
    send Enter;
    Handle.recompute_view handle;
    let intent = List.hd_exn !consumed in
    assert (List.length !consumed = 1 && intent.line = 1 && intent.byte_column = 4);
    assert (String.equal intent.literal "needle" && String.equal intent.expected_text "界\tneedle needle\n");
    assert (String.is_prefix intent.path ~prefix:(root ^ "/file"));
    Handle.recompute_view handle;
    assert (List.length !consumed = 1);
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    let output = [%expect.output] in
    assert (String.is_substring output ~substring:"(kind Block)");
    Runtime.finished runtime)
    ~finally:(fun () ->
      Runtime.cancel runtime;
      let%map () = Runtime.finished runtime in
      Array.iter (Sys_unix.readdir root) ~f:(fun p -> Core_unix.unlink (root ^ "/" ^ p));
      Core_unix.rmdir root) in
  ignore ([%expect.output] : string);
  print_endline "real content provider/frontend, query replacement and typed acceptance passed";
  [%expect {| real content provider/frontend, query replacement and typed acceptance passed |}];
  return ()
;;

let%expect_test "content frontend interrupted paste and resize cancel search without document leakage" =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-content-interrupt" "") in
  Out_channel.write_all (root ^ "/file.ml") ~data:"needle\n";
  let runtime = Runtime.create
    ~limits:{ Ches_content_search.Provider.Limits.default with debounce = Time_ns.Span.of_int_ms 100 } () in
  let%bind () = Monitor.protect (fun () ->
    let text = Ches_core.Text_buffer.of_string "untouched" |> Result.map_error
      ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
    let controller = Ches_app.Controller.create (Ches_core.Editor.create ~cell_width:Cell_map.width text) in
    let opened = Runtime.open_picker runtime (Ui_state.create ~tiles_visible:false controller)
      ~root ~width:80 ~height:24 |> Or_error.ok_exn in
    let session = Content_picker_tile.session (Option.value_exn (Ui_state.content_picker opened)) in
    let consumed = ref 0 in
    let content_picker : Ches_ui.Editor_view.Content_picker_host.t =
      { initial_ui = opened; runtime; consume = (fun _ -> incr consumed) } in
    let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 80; height = 24 }
      (Ches_ui.Editor_view.app ~content_picker controller ~exit:(fun () -> Effect.Ignore)) in
    let send event = Bonsai_term_test.send_event handle event in
    List.iter (String.to_list "needle") ~f:(fun c -> send (Key_press { key = ASCII c; mods = [] }));
    Handle.recompute_view handle;
    send (Paste `Start);
    send (Key_press { key = ASCII 'O'; mods = [] });
    Bonsai_term_test.set_dimensions handle { width = 13; height = 5 };
    Handle.recompute_view handle;
    assert (Model.closed session);
    send (Key_press { key = ASCII 'L'; mods = [] });
    send (Paste `End);
    Bonsai_term_test.set_dimensions handle { width = 80; height = 24 };
    let%bind () = Runtime.finished runtime in
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 150) in
    Handle.recompute_view handle;
    assert (!consumed = 0);
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    let output = [%expect.output] in
    assert (String.is_substring output ~substring:"untouched");
    assert (String.is_substring output ~substring:"paste dropped");
    assert (not (String.is_substring output ~substring:"ON DISK"));
    return ())
    ~finally:(fun () ->
      Runtime.cancel runtime;
      let%map () = Runtime.finished runtime in
      Core_unix.unlink (root ^ "/file.ml"); Core_unix.rmdir root) in
  ignore ([%expect.output] : string);
  print_endline "frontend interrupted paste/resize isolated and search cancelled";
  [%expect {| frontend interrupted paste/resize isolated and search cancelled |}];
  return ()
;;
