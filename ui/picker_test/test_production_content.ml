open! Core
open! Async
open Bonsai_test
open Bonsai_term
open Ches_screen
module Editor = Ches_core.Editor
module Text_buffer = Ches_core.Text_buffer
module Expect_test_config = Async.Expect_test_config

let%expect_test "production acceptance checks raw line, literal and UTF-8 boundaries transactionally" =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-content-validation" "") in
  let target = root ^ "/target.ml" in
  Out_channel.write_all target ~data:"界\tneedle\n";
  let controller = Ches_app.Controller.create (Editor.create ~cell_width:Cell_map.width Text_buffer.empty) in
  let initial = Ui_state.create controller in
  let intent : Ches_tile.View_id.t Ches_content_picker.Model.intent =
    { token = Content_picker_tile.id; path = target; line = 1; byte_column = 4;
      end_byte = 10; expected_text = "界\tneedle\n"; literal = "needle" } in
  let accept ui intent = fst (Ui_state.apply ui ~width:100 ~height:30
    (Ui_state.Input.Content_picker_accept intent)) in
  List.iter
    [ { intent with expected_text = "界\tneedle" }
    ; { intent with literal = "NEEDLE" }
    ; { intent with line = 0 }
    ; { intent with byte_column = -1 }
    ; { intent with end_byte = 11 }
    ; { intent with byte_column = 1; end_byte = 3; literal = String.sub "界" ~pos:1 ~len:2 }
    ] ~f:(fun bad ->
      let rejected = accept initial bad in
      assert (List.length (Ches_app.Session.buffers (Ui_state.session rejected)) = 1);
      assert (Option.is_none (Editor.path (Ches_app.Controller.editor (Ui_state.controller rejected)))));
  List.iter [ "needle\r\n"; "needle\000"; String.of_char (Char.of_int_exn 255) ]
    ~f:(fun unsupported ->
      Out_channel.write_all target ~data:unsupported;
      let rejected = accept initial { intent with expected_text = unsupported } in
      assert (List.length (Ches_app.Session.buffers (Ui_state.session rejected)) = 1));
  Out_channel.write_all target ~data:"界\tneedle\n";
  let opened = accept initial intent in
  let editor = Ches_app.Controller.editor (Ui_state.controller opened) in
  assert (Editor.cursor editor = 4);
  assert ([%equal: int * int] (Editor.display_position_of_offset editor 4 |> Or_error.ok_exn) (1, 9));
  assert (List.length (Ches_app.Session.buffers (Ui_state.session opened)) = 2);
  let original_id = Ches_app.Session.active_id (Ui_state.session initial) |> Option.value_exn in
  let returned = Ui_state.activate_buffer opened ~width:100 ~height:30 original_id |> Or_error.ok_exn in
  let rejected = accept returned { intent with expected_text = "stale\n" } in
  assert (Option.equal Ches_app.Buffer_id.equal (Ches_app.Session.active_id (Ui_state.session rejected))
    (Some original_id));
  (* A final line without LF is accepted exactly, not normalized. *)
  let final_path = root ^ "/final.ml" in
  Out_channel.write_all final_path ~data:"needle";
  let final = accept rejected { intent with path = final_path; byte_column = 0; end_byte = 6;
    expected_text = "needle" } in
  assert (Editor.cursor (Ches_app.Controller.editor (Ui_state.controller final)) = 0);
  (* Already-open targets are authoritative even after deletion; no reread. *)
  Core_unix.unlink target;
  let revisited = accept final intent in
  assert (Editor.cursor (Ches_app.Controller.editor (Ui_state.controller revisited)) = 4);
  Ches_app.Session.dispose (Ui_state.session revisited);
  Ches_app.Controller.close controller;
  Core_unix.unlink final_path;
  Core_unix.rmdir root;
  print_endline "raw validation, UTF-8 boundaries, display cells and deleted retained target passed";
  [%expect {| raw validation, UTF-8 boundaries, display cells and deleted retained target passed |}];
  return ()
;;

let%expect_test "production content binding and catalog navigate, reject changed and missing files" =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-production-content" "") in
  let target = root ^ "/target.ml" in
  Out_channel.write_all (root ^ "/dune-project") ~data:"";
  Out_channel.write_all (root ^ "/start.ml") ~data:"start document";
  let target_text = String.concat (List.init 80 ~f:(fun _ -> "padding\n")) ^ "界\tneedle\n" in
  Out_channel.write_all target ~data:target_text;
  let controller = Ches_app.Controller.open_file ~cell_width:Cell_map.width
    (root ^ "/start.ml") |> Or_error.ok_exn in
  let%bind () = Monitor.protect (fun () ->
    let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 100; height = 30 }
      (Ches_ui.Editor_view.app controller ~exit:(fun () -> Effect.Ignore)) in
    let key key = Bonsai_term_test.send_event handle (Key_press { key; mods = [] }) in
    let type_text s = String.iter s ~f:(fun c -> key (ASCII c)) in
    let view () = Handle.recompute_view handle;
      Bonsai_term_test.print_view (Bonsai_term_test.last_view handle); [%expect.output] in
    let wait predicate =
      let rec loop () = if predicate (view ()) then return () else
        let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 2) in loop () in
      let%map result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (loop ()) in
      match result with `Result () -> () | `Timeout -> failwith (view ()) in
    let search () = type_text " fgneedle";
      wait (fun s -> String.is_substring s ~substring:"target.ml:81"
        && not (String.is_substring s ~substring:"Loading")) in
    type_text "iDIRTY"; key Escape;
    (* Cancel/reopen while debounce/awaited work is pending. *)
    type_text " fgobsolete"; key Escape;
    let%bind () = search () in
    key Enter;
    let%bind () = wait (fun s -> String.is_substring s ~substring:"81:3") in
    assert (String.is_substring (view ()) ~substring:"needle");
    (* Dirty edit elsewhere still permits the unchanged searched line. *)
    type_text "ggiUNSAVED"; key Escape;
    let%bind () = search () in
    key Enter;
    let%bind () = wait (fun s -> String.is_substring s ~substring:"81:3") in
    (* Disk still matches, but retained dirty line no longer does. *)
    type_text "iCHANGED"; key Escape;
    let%bind () = search () in
    key Enter;
    let%bind () = wait (fun s -> String.is_substring s ~substring:"Content result changed") in
    assert (String.is_substring (view ()) ~substring:"CHANGED");
    (* Undo history survived both successful and rejected activation. *)
    type_text "u";
    let%bind () = search () in key Enter;
    let%bind () = wait (fun s -> String.is_substring s ~substring:"81:3") in
    (* Catalog dispatch uses the production runtime. *)
    type_text " ccSearch project contents"; key Enter;
    let%bind () = wait (fun s -> String.is_substring s ~substring:"ON DISK") in
    type_text "needle";
    let%bind () = wait (fun s -> String.is_substring s ~substring:"target.ml:81") in
    key Escape;
    (* New results disappearing or changing after discovery don't switch tabs. *)
    Out_channel.write_all (root ^ "/gone.ml") ~data:"vanishing\n";
    type_text " fgvanishing";
    let%bind () = wait (fun s -> String.is_substring s ~substring:"gone.ml:1") in
    Core_unix.unlink (root ^ "/gone.ml"); key Enter;
    let%bind () = wait (fun s -> String.is_substring s ~substring:"file no longer exists") in
    assert (not (Sys_unix.file_exists_exn (root ^ "/gone.ml")));
    Out_channel.write_all (root ^ "/gone.ml") ~data:"vanishing\n";
    type_text " fgvanishing";
    let%bind () = wait (fun s -> String.is_substring s ~substring:"gone.ml:1") in
    Out_channel.write_all (root ^ "/gone.ml") ~data:"replacement\n"; key Enter;
    let%bind () = wait (fun s -> String.is_substring s ~substring:"Content result changed") in
    assert (String.is_substring (view ()) ~substring:"needle");
    type_text " Q"; ignore (view () : string); return ())
    ~finally:(fun () ->
      Ches_app.Controller.close controller;
      List.iter [ "dune-project"; "start.ml"; "target.ml"; "gone.ml" ]
        ~f:(fun p -> if Sys_unix.file_exists_exn (root ^ "/" ^ p) then Core_unix.unlink (root ^ "/" ^ p));
      Core_unix.rmdir root; return ()) in
  ignore ([%expect.output] : string);
  print_endline "production content navigation, dirty validation, undo, command and failed opens passed";
  [%expect {| production content navigation, dirty validation, undo, command and failed opens passed |}];
  return ()
;;
