open! Core
open! Async
open Bonsai_test
open Bonsai_term
open Ches_screen
module Expect_test_config = Async.Expect_test_config

let%expect_test "batched picker activation routes following keys and cancel to the new owner" =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-picker-batch" "") in
  let controller = Ches_app.Controller.create (Ches_core.Editor.create
    ~cell_width:Cell_map.width Ches_core.Text_buffer.empty) in
  let files = Ches_file_picker_host.Runtime.create () in
  let contents = Ches_content_picker_host.Runtime.create () in
  let activate ui =
    let ui, file = Ui_state.take_file_picker_activation ui in
    let ui = if file then Ches_file_picker_host.Runtime.open_picker files ui
      ~root ~width:100 ~height:30 |> Or_error.ok_exn else ui in
    let ui, content = Ui_state.take_content_picker_activation ui in
    if content then Ches_content_picker_host.Runtime.open_picker contents ui
      ~root ~width:100 ~height:30 |> Or_error.ok_exn else ui in
  let batch ui text = Ui_state.apply_all ~after_step:activate ui ~width:100 ~height:30
    (String.to_list text |> List.map ~f:(fun c -> Ui_state.Input.Key (Ches_input.Key.Char (Uchar.of_char c)))) |> fst in
  let initial = Ui_state.create controller in
  let ui = batch initial " ffquery" in
  assert (String.equal (Ches_file_picker.Interaction.query
    (File_picker_tile.session (Option.value_exn (Ui_state.file_picker ui)))) "query");
  let ui = fst (Ui_state.apply ui ~width:100 ~height:30 (Key Escape)) in
  let ui = batch ui " fgneedle" in
  assert (String.equal (Ches_content_picker.Model.query
    (Content_picker_tile.session (Option.value_exn (Ui_state.content_picker ui)))) "needle");
  let ui = fst (Ui_state.apply ui ~width:100 ~height:30 (Key Escape)) in
  assert (Ches_core.Text_buffer.length (Ches_core.Editor.text (Ches_app.Controller.editor (Ui_state.controller ui))) = 0);
  let keys text = String.to_list text |> List.map ~f:(fun c ->
    Ui_state.Input.Key (Ches_input.Key.Char (Uchar.of_char c))) in
  let cancelled, _ = Ui_state.apply_all ~after_step:activate ui ~width:100 ~height:30
    (keys " ffquery" @ [ Ui_state.Input.Key Escape ] @ keys " fgneedle" @ [ Ui_state.Input.Key Escape ]) in
  assert (Option.is_none (Ui_state.file_picker cancelled));
  assert (Option.is_none (Ui_state.content_picker cancelled));
  let _, requests = Ui_state.take_file_requests cancelled in
  assert (List.is_empty requests);
  let _, requests = Ui_state.take_content_requests cancelled in
  assert (List.is_empty requests);
  let notice = Ui_state.with_notice ~source:"content picker" cancelled "bad\nerror" in
  let frame = Frame.render notice ~width:100 ~height:30 in
  let rendered = String.concat (List.concat_map frame.rows ~f:(List.map ~f:(fun span -> span.Frame.Span.text))) in
  assert (String.is_substring rendered ~substring:"[content picker]");
  let raised = Ches_app.Session.open_or_activate ~validate:(fun _ -> failwith "validation exception")
    (Ui_state.session ui) (root ^ "/new.ml") in
  assert (Result.is_error raised);
  assert (List.length (Ches_app.Session.buffers (Ui_state.session ui)) = 1);
  Ches_file_picker_host.Runtime.cancel files;
  Ches_content_picker_host.Runtime.cancel contents;
  let%bind () = Ches_file_picker_host.Runtime.finished files in
  let%bind () = Ches_content_picker_host.Runtime.finished contents in
  Ches_app.Session.dispose (Ui_state.session ui);
  Core_unix.rmdir root;
  print_endline "batched queries, cancellation and exception rejection passed";
  [%expect {| batched queries, cancellation and exception rejection passed |}];
  return ()
;;

let%expect_test "production binding opens session buffers, retains dirty text and scope, and reports failed opens" =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-production-files" "") in
  Core_unix.mkdir (root ^ "/nested");
  Out_channel.write_all (root ^ "/dune-project") ~data:"";
  Out_channel.write_all (root ^ "/nested/dune-project") ~data:"";
  Out_channel.write_all (root ^ "/alpha.ml") ~data:"original alpha";
  Out_channel.write_all (root ^ "/nested/beta.ml") ~data:"beta document";
  Out_channel.write_all (root ^ "/gamma.ml") ~data:"gamma document";
  let controller = Ches_app.Controller.open_file ~cell_width:Cell_map.width
    (root ^ "/alpha.ml") |> Or_error.ok_exn in
  let%bind () = Monitor.protect (fun () ->
    let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 100; height = 30 }
      (Ches_ui.Editor_view.app controller ~exit:(fun () -> Effect.Ignore)) in
    let key key = Bonsai_term_test.send_event handle (Key_press { key; mods = [] }) in
    let type_text text = String.iter text ~f:(fun c -> key (ASCII c)) in
    let view () =
      Handle.recompute_view handle;
      Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
      [%expect.output] in
    let wait predicate =
      let rec loop () =
        if predicate (view ()) then return () else
          let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 2) in loop () in
      let%map result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (loop ()) in
      (match result with `Result () -> () | `Timeout -> failwith (view ())) in
    let open_picker () =
      type_text " ff";
      wait (fun output -> String.is_substring output ~substring:"gamma.ml"
        && not (String.is_substring output ~substring:"Loading")
        && not (String.is_substring output ~substring:"Filtering")) in
    let select query =
      type_text query;
      wait (fun output -> String.is_substring output ~substring:query
        && not (String.is_substring output ~substring:"Filtering")) in
    type_text "iDIRTY"; key Escape;
    let%bind () = open_picker () in
    let%bind () = select "beta" in
    key Enter;
    let%bind () = wait (fun output -> String.is_substring output ~substring:"beta document") in
    (* Nested project markers must not retarget scope on tab activation. *)
    let%bind () = open_picker () in
    let%bind () = select "alpha" in
    Core_unix.unlink (root ^ "/alpha.ml");
    key Enter;
    let%bind () = wait (fun output -> String.is_substring output ~substring:"DIRTYoriginal alpha") in
    assert (not (Sys_unix.file_exists_exn (root ^ "/alpha.ml")));
    (* Restore only disk: the retained dirty buffer must still win. *)
    Out_channel.write_all (root ^ "/alpha.ml") ~data:"replacement disk";
    let%bind () = open_picker () in
    let%bind () = select "gamma" in
    Core_unix.unlink (root ^ "/gamma.ml");
    key Enter;
    let%bind () = wait (fun output -> String.is_substring output ~substring:"file no longer exists") in
    assert (String.is_substring (view ()) ~substring:"DIRTYoriginal alpha");
    assert (not (Sys_unix.file_exists_exn (root ^ "/gamma.ml")));
    (* A discovered regular path replaced by a directory is not a file buffer. *)
    Out_channel.write_all (root ^ "/gamma.ml") ~data:"gamma";
    let%bind () = open_picker () in
    let%bind () = select "gamma" in
    Core_unix.unlink (root ^ "/gamma.ml"); Core_unix.mkdir (root ^ "/gamma.ml");
    key Enter;
    let%bind () = wait (fun output -> String.is_substring output ~substring:"is a directory") in
    assert (String.is_substring (view ()) ~substring:"DIRTYoriginal alpha");
    (* Focus has returned: editing goes to the retained document, not the query. *)
    type_text "iAFTER"; key Escape;
    assert (String.is_substring (view ()) ~substring:"AFTER");
    Core_unix.rmdir (root ^ "/gamma.ml");
    (* The production palette dispatch uses the same runtime, not a test host. *)
    Out_channel.write_all (root ^ "/gamma.ml") ~data:"gamma";
    type_text " cc"; type_text "Find project files"; key Enter;
    let%bind () = wait (fun output -> String.is_substring output ~substring:"gamma.ml"
      && not (String.is_substring output ~substring:"Loading")
      && not (String.is_substring output ~substring:"Filtering")) in
    key Escape;
    assert (String.is_substring (view ()) ~substring:"AFTER");
    Core_unix.unlink (root ^ "/gamma.ml");
    type_text " Q";
    ignore (view () : string);
    return ())
    ~finally:(fun () ->
      Ches_app.Controller.close controller;
      List.iter [ "alpha.ml"; "dune-project"; "nested/beta.ml"; "nested/dune-project" ]
        ~f:(fun path -> Core_unix.unlink (root ^ "/" ^ path));
      Core_unix.rmdir (root ^ "/nested"); Core_unix.rmdir root;
      return ()) in
  ignore ([%expect.output] : string);
  print_endline "production file binding, dirty revisit, stable nested scope and failure focus passed";
  [%expect {| production file binding, dirty revisit, stable nested scope and failure focus passed |}];
  return ()
;;
