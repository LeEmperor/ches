open! Core
open! Async
open Bonsai_test
open Bonsai_term
open Ches_screen
module Runtime = Ches_file_picker_host.Runtime
module Interaction = Ches_file_picker.Interaction
module Model = Ches_file_picker.Model
module Expect_test_config = Async.Expect_test_config

let%expect_test "frontend chains async turns and consumes only after release, without a live binding" =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-picker-ui" "") in
  List.iter (List.init 300 ~f:(fun n -> sprintf "file%03d.ml" n)) ~f:(fun p ->
    Out_channel.write_all (root ^ "/" ^ p) ~data:"");
  let runtime = Runtime.create () in
  let cursor_output = ref "" in
  let%bind () = Monitor.protect (fun () ->
    let text = Ches_core.Text_buffer.of_string "underlying" |> Result.map_error
      ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
    let controller = Ches_app.Controller.create
      (Ches_core.Editor.create ~cell_width:Cell_map.width text) in
    let initial = Ui_state.create ~tiles_visible:false controller in
    let opened = Runtime.open_picker runtime initial ~root ~width:80 ~height:24 |> Or_error.ok_exn in
    let session = File_picker_tile.session (Option.value_exn (Ui_state.file_picker opened)) in
    let consumed = ref [] in
    let file_picker : Ches_ui.Editor_view.File_picker_host.t =
      { initial_ui = opened; runtime
      ; consume = (fun intent ->
          assert (Interaction.closed session);
          consumed := intent.Model.Request.path :: !consumed) } in
    let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 80; height = 24 }
      (Ches_ui.Editor_view.app ~file_picker controller ~exit:(fun () -> Effect.Ignore)) in
    let rec settle () =
      Handle.recompute_view handle;
      let status = (Model.discovery (Interaction.model session)).status in
      if Interaction.busy session || (match status with Loading | Partial -> true | _ -> false)
      then let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in settle ()
      else return () in
    let%bind result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (settle ()) in
    assert (match result with `Result () -> true | `Timeout -> false);
    assert (Interaction.prepared_count session = 300);
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    let output = [%expect.output] in
    cursor_output := output;
    assert (String.is_substring output ~substring:"file000.ml");
    assert (not (String.is_substring output ~substring:"Filtering..."));
    List.iter (String.to_list "file299") ~f:(fun c ->
      Bonsai_term_test.send_event handle (Key_press { key = ASCII c; mods = [] }));
    let%bind result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (settle ()) in
    assert (match result with `Result () -> true | `Timeout -> false);
    assert (List.length (Model.results (Interaction.model session)) = 1);
    assert (Interaction.prepared_count session = 300);
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    let output = [%expect.output] in
    cursor_output := !cursor_output ^ output;
    assert (String.is_substring output ~substring:"file299.ml");
    assert (not (String.is_substring output ~substring:"Filtering..."));
    Bonsai_term_test.send_event handle (Key_press { key = Enter; mods = [] });
    Handle.recompute_view handle;
    assert ([%equal: string list] !consumed [ root ^ "/file299.ml" ]);
    Handle.recompute_view handle;
    assert (List.length !consumed = 1);
    Runtime.finished runtime)
    ~finally:(fun () ->
      Runtime.cancel runtime;
      let%map () = Runtime.finished runtime in
      Array.iter (Sys_unix.readdir root) ~f:(fun p -> Core_unix.unlink (root ^ "/" ^ p));
      Core_unix.rmdir root) in
  (* The number of redraws depends on actual process delivery. Assert cursor
     ownership, not a timing-dependent sequence of identical cursor writes. *)
  let output = !cursor_output ^ [%expect.output] in
  assert (String.is_substring output ~substring:"(kind Bar)");
  assert (String.is_substring output ~substring:"(kind Block)");
  print_endline "bounded frontend scheduling, query, cursor and acceptance passed";
  [%expect {| bounded frontend scheduling, query, cursor and acceptance passed |}];
  return ()
;;

let%expect_test "frontend deactivation drops retained file results and rejects late work" =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-picker-deactivate" "") in
  Out_channel.write_all (root ^ "/file.ml") ~data:"";
  let runtime = Runtime.create () in
  let%bind () = Monitor.protect (fun () ->
    let text = Ches_core.Text_buffer.of_string "untouched" |> Result.map_error
      ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
    let controller = Ches_app.Controller.create
      (Ches_core.Editor.create ~cell_width:Cell_map.width text) in
    let state = ref (Runtime.open_picker runtime (Ui_state.create controller)
      ~root ~width:80 ~height:24 |> Or_error.ok_exn) in
    let%bind result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10)
      (Runtime.pump runtime ~current:(fun () -> !state) ~inject:(fun inputs ->
         state := fst (Ui_state.apply_all !state ~width:80 ~height:24 inputs);
         return ())) in
    assert (match result with `Result () -> true | `Timeout -> false);
    let session = File_picker_tile.session (Option.value_exn (Ui_state.file_picker !state)) in
    let snapshot = Model.discovery (Interaction.model session) in
    assert (Interaction.prepared_count session = 1);
    assert (List.length (Model.results (Interaction.model session)) = 1);
    let consumed = ref 0 in
    let file_picker : Ches_ui.Editor_view.File_picker_host.t =
      { initial_ui = !state; runtime; consume = (fun _ -> incr consumed) } in
    let active = Bonsai.Expert.Var.create true in
    let component ~dimensions (local_ graph) =
      let open Bonsai.Let_syntax in
      let both =
        match%sub Bonsai.Expert.Var.value active with
        | false -> Bonsai.return (View.none, (fun _ -> Effect.Ignore))
        | true ->
          let ~view, ~handler = Ches_ui.Editor_view.app ~file_picker controller
            ~exit:(fun () -> Effect.Ignore) ~dimensions graph in
          let%arr view and handler in view, handler in
      let view = let%arr both in fst both in
      let handler = let%arr both in snd both in
      ~view, ~handler in
    let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 80; height = 24 }
      component in
    Handle.recompute_view handle;
    Bonsai_term_test.send_event handle (Key_press { key = ASCII 'x'; mods = [] });
    Handle.recompute_view handle;
    assert (Interaction.busy session);
    Bonsai.Expert.Var.set active false;
    Handle.recompute_view handle;
    assert (Interaction.closed session);
    assert (not (Interaction.busy session));
    assert (List.is_empty (Model.discovery (Interaction.model session)).candidates);
    assert (List.is_empty (Model.results (Interaction.model session)));
    assert (not (Interaction.install session snapshot));
    Interaction.work session ~budget:128;
    Interaction.accept session ~release:(fun () -> failwith "late release")
      ~consume:(fun _ -> incr consumed);
    let%bind () = Scheduler.yield () in
    Handle.recompute_view handle;
    assert (Interaction.closed session && not (Interaction.busy session));
    assert (!consumed = 0);
    Runtime.finished runtime)
    ~finally:(fun () ->
      Runtime.cancel runtime;
      let%map () = Runtime.finished runtime in
      Core_unix.unlink (root ^ "/file.ml"); Core_unix.rmdir root) in
  ignore ([%expect.output] : string);
  print_endline "deactivation drops file session and late acceptance stays inert";
  [%expect {| deactivation drops file session and late acceptance stays inert |}];
  return ()
;;
