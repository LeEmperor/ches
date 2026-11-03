open! Core
open! Async
open Bonsai_test
open Bonsai_term
module App = Ches_app
module Q = Ches_error.Language_query
module Expect_test_config = Async.Expect_test_config

let%expect_test "frontend follows rendered destination selection without activation or history" =
  let root = Filename_unix.temp_dir "ches-navigation-frontend" "" in
  let a = root ^ "/a.ml" and b = root ^ "/b.ml" in
  Out_channel.write_all a ~data:"DISK_ORIGIN\n";
  Out_channel.write_all b ~data:"SELECTED_DISK_PREVIEW\n";
  let emit = ref (fun (_ : Ches_error.Source_event.t) -> ()) in
  let queries = ref [] in
  let source = Ches_source.Source.create (fun ~emit:publish ->
    emit := publish;
    { handle = (function Query q -> queries := q :: !queries | _ -> ()); stop = Fn.id }) in
  let%bind () = Monitor.protect (fun () ->
    let controller = App.Controller.open_file ~cell_width:Ches_screen.Cell_map.width a |> Or_error.ok_exn in
    let dirty = Ches_core.Text_buffer.of_string "DIRTY_RETAINED_PREVIEW\n" |> Result.ok |> Option.value_exn in
    let controller = App.Controller.rebase_text controller
      ~saved:(Ches_core.Editor.text (App.Controller.editor controller)) ~text:dirty in
    let parses = App.Controller.highlight_parse_count controller in
    let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 120; height = 30 }
      (Ches_ui.Editor_view.app ~source controller ~exit:(fun () -> Effect.Ignore)) in
    let output () =
      Handle.recompute_view handle;
      Bonsai_term_test.print_view (Bonsai_term_test.last_view handle); [%expect.output] in
    let rec wait predicate =
      let s = output () in
      if predicate s then return s else let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 5) in wait predicate in
    let wait predicate =
      let%map result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 5) (wait predicate) in
      match result with `Result s -> s | `Timeout -> failwith "navigation frontend did not settle" in
    let send ?(mods = []) key =
      Bonsai_term_test.send_event handle (Key_press { key; mods }); Handle.recompute_view handle in
    ignore (output () : string);
    send (ASCII 'g'); send (ASCII 'r');
    let%bind _ = wait (fun _ -> not (List.is_empty !queries)) in
    let query = List.hd_exn !queries in
    let target path : Q.target =
      let position : Q.position = { line = 0; character = 0 } in
      let range : Q.range = { start = position; stop = position } in
      { path; range; selection = range; encoding = Utf8 } in
    !emit (Query_result { token = query.token; cursor = query.cursor; kind = query.kind;
      source = "fake"; result = Locations [target a; target b] });
    let%bind _ = wait (fun s -> String.is_substring s ~substring:"buffer r") in
    send Tab;
    let%bind s = wait (fun s -> String.is_substring s ~substring:"SELECTED_DISK_PREVIEW") in
    assert (String.is_substring s ~substring:"DIRTY_RETAINED_PREVIEW");
    (* A-B-A in one frontend turn must follow both transitions. *)
    Bonsai_term_test.send_event handle (Key_press { key = Tab; mods = [Shift] });
    Bonsai_term_test.send_event handle (Key_press { key = Tab; mods = [] });
    Handle.recompute_view handle;
    let%bind _ = wait (fun s -> String.is_substring s ~substring:"SELECTED_DISK_PREVIEW") in
    let count = List.length !queries in
    for _ = 1 to 20 do ignore (output () : string) done;
    assert (List.length !queries = count);
    assert (App.Controller.highlight_parse_count controller = parses);
    send Escape;
    (* Had browsing activated B or recorded a jump, history back/forward would
       expose B here after closing the picker. *)
    send ~mods:[Ctrl] (ASCII 'o'); send Tab;
    let s = output () in
    assert (String.is_substring s ~substring:"DIRTY_RETAINED_PREVIEW");
    assert (not (String.is_substring s ~substring:"SELECTED_DISK_PREVIEW"));
    return ())
    ~finally:(fun () -> Ches_source.Source.stop source;
      Core_unix.unlink a; Core_unix.unlink b; Core_unix.rmdir root; return ()) in
  ignore ([%expect.output] : string);
  print_endline "rendered retained/disk selection, batched transitions, stable frames and no preview jumps";
  [%expect {| rendered retained/disk selection, batched transitions, stable frames and no preview jumps |}]; return ()
