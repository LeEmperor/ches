open! Core
open! Async
open Bonsai_test
open Bonsai_term
open Ches_screen
module App = Ches_app
module Model = Ches_file_picker.Model
module Runtime = Ches_file_picker_host.Runtime
module Preview = Ches_file_preview_model.Model
module Expect_test_config = Async.Expect_test_config

let%expect_test "production frontend preview follows rapid selection, dirty buffer, resize and closure" =
  let root = Filename_unix.realpath
    (Filename_unix.temp_dir ~in_dir:"/tmp/opencode" "ches-preview-frontend" "") in
  let a = root ^ "/a.ml" and b = root ^ "/b.ml" in
  Out_channel.write_all a ~data:"ON_DISK_A\n";
  Out_channel.write_all b ~data:"DISK_B_PREVIEW\n";
  let runtime = Runtime.create () in
  let%bind () = Monitor.protect (fun () ->
    let controller = App.Controller.open_file ~cell_width:Cell_map.width a |> Or_error.ok_exn in
    let dirty = Ches_core.Text_buffer.of_string "DIRTY_A_PREVIEW\n\t界é\027\n"
      |> Result.ok |> Option.value_exn in
    let controller = App.Controller.rebase_text controller
      ~saved:(Ches_core.Editor.text (App.Controller.editor controller)) ~text:dirty in
    let state = ref (Runtime.open_picker runtime (Ui_state.create controller)
      ~root ~width:140 ~height:24 |> Or_error.ok_exn) in
    let%bind () = Runtime.pump runtime ~current:(fun () -> !state) ~inject:(fun inputs ->
      state := fst (Ui_state.apply_all !state ~width:140 ~height:24 inputs); return ()) in
    let picker = Option.value_exn (Ui_state.file_picker !state) in
    let session = Ui_state.session !state in
    let active = App.Session.active_id session in
    let parses = App.Controller.highlight_parse_count controller in
    let consumed = ref [] in
    let host : Ches_ui.Editor_view.File_picker_host.t =
      { initial_ui = !state; runtime; consume = (fun intent ->
          assert (Ches_file_picker.Interaction.closed (File_picker_tile.session picker));
          consumed := intent.Model.Request.path :: !consumed) } in
    let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 140; height = 24 }
      (Ches_ui.Editor_view.app ~file_picker:host controller ~exit:(fun () -> Effect.Ignore)) in
    let output () =
      Handle.recompute_view handle;
      Bonsai_term_test.print_view (Bonsai_term_test.last_view handle); [%expect.output] in
    let rec wait_for predicate =
      let s = output () in
      if predicate s then return s
      else let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 2) in wait_for predicate in
    let wait predicate =
      let%map result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (wait_for predicate) in
      match result with `Result s -> s | `Timeout -> failwith "preview did not settle" in
    let send ?(mods = []) key =
      Bonsai_term_test.send_event handle (Key_press { key; mods }); Handle.recompute_view handle in
    let%bind s = wait (fun s -> String.is_substring s ~substring:"buffer r") in
    assert (String.is_substring s ~substring:"Preview | a.ml");
    (match (Option.value_exn (File_picker_tile.preview picker)).Preview.state with
     | Ready payload -> assert (String.is_prefix payload.text ~prefix:"DIRTY_A_PREVIEW")
     | _ -> assert false);
    assert (not (String.is_substring s ~substring:"ON_DISK_A"));
    let original = Option.value_exn (File_picker_tile.preview picker) in
    (* Both native events are pending in one frontend frame. Synchronizing only
       the final A identity would incorrectly keep the pre-batch generation. *)
    Bonsai_term_test.send_event handle (Key_press { key = Tab; mods = [] });
    Bonsai_term_test.send_event handle (Key_press { key = Tab; mods = [ Shift ] });
    Handle.recompute_view handle;
    assert (not (File_picker_tile.install_preview picker original));
    let%bind _ = wait (fun s -> String.is_substring s ~substring:"buffer r") in
    send Tab;
    assert (not (File_picker_tile.install_preview picker original));
    send ~mods:[ Shift ] Tab;
    assert (not (File_picker_tile.install_preview picker original));
    send Tab;
    let%bind s = wait (fun s -> String.is_substring s ~substring:"DISK_B_PREVIEW") in
    assert (String.is_substring s ~substring:"Preview | b.ml");
    let disk = Option.value_exn (File_picker_tile.preview picker) in
    assert (List.is_empty !consumed && List.length (App.Session.buffers session) = 1);
    assert (Option.equal App.Buffer_id.equal active (App.Session.active_id session));
    assert (App.Controller.highlight_parse_count controller = parses);
    Bonsai_term_test.set_dimensions handle { width = 80; height = 24 };
    let s = output () in
    assert (not (String.is_substring s ~substring:"Preview |"));
    assert (not (File_picker_tile.install_preview picker disk));
    Bonsai_term_test.set_dimensions handle { width = 140; height = 24 };
    let%bind _ = wait (fun s -> String.is_substring s ~substring:"DISK_B_PREVIEW") in
    send Enter;
    assert ([%equal: string list] !consumed [ b ]);
    assert (Option.is_none (File_picker_tile.preview picker));
    assert (not (File_picker_tile.install_preview picker disk));
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
    let s = output () in
    assert (not (String.is_substring s ~substring:"Preview |"));
    (* Real command reopens a fresh production session; tiny resize releases it. *)
    List.iter (String.to_list " ff") ~f:(fun c -> send (ASCII c));
    let%bind _ = wait (fun s -> String.is_substring s ~substring:"buffer r") in
    Bonsai_term_test.set_dimensions handle { width = 13; height = 5 };
    let s = output () in
    assert (not (String.is_substring s ~substring:"Preview |"));
    Bonsai_term_test.set_dimensions handle { width = 140; height = 24 };
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
    let s = output () in
    assert (not (String.is_substring s ~substring:"Preview |"));
    Runtime.finished runtime)
    ~finally:(fun () ->
      Runtime.cancel runtime;
      let%map () = Runtime.finished runtime in
      Core_unix.unlink a; Core_unix.unlink b; Core_unix.rmdir root) in
  ignore ([%expect.output] : string);
  print_endline "guarded frontend preview, dirty snapshot, no open before Enter, resize and close passed";
  [%expect {| guarded frontend preview, dirty snapshot, no open before Enter, resize and close passed |}];
  return ()
