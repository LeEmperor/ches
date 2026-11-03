open! Core
open! Async
open Bonsai_test
open Bonsai_term
module Q = Ches_error.Language_query
module Expect_test_config = Async.Expect_test_config

let%expect_test "automatic signature intents reach an asynchronous source without blocking further edits" =
  let requests = ref [] in
  let emit = ref (fun (_ : Ches_error.Source_event.t) -> ()) in
  let source = Ches_source.Source.create (fun ~emit:publish ->
    emit := publish;
    { handle = (function
        | Query q -> requests := !requests @ [q]
        | _ -> ())
    ; stop = Fn.id }) in
  let text = Ches_core.Text_buffer.of_string "" |> Result.map_error
    ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
  let controller = Ches_app.Controller.create
    (Ches_core.Editor.create ~path:"/tmp/signature-frontend.ml"
      ~cell_width:Ches_screen.Cell_map.width text) in
  let handle = Bonsai_term_test.create_handle ~initial_dimensions:{width = 100; height = 25}
    (Ches_ui.Editor_view.app ~source controller ~exit:(fun () -> Effect.Ignore)) in
  let settle () =
    Handle.recompute_view handle;
    let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 5) in
    Handle.recompute_view handle in
  let send c =
    Bonsai_term_test.send_event handle (Key_press {key = ASCII c; mods = []}) in
  let%bind () = settle () in
  List.iter ['i'; '('; 'a'] ~f:(fun c -> send c; Handle.recompute_view handle);
  let%bind () = settle () in
  assert (List.length !requests = 2);
  assert (match (List.last_exn !requests).kind with
    | Signature_help {automatic = true; character = Some "a"; _} -> true | _ -> false);
  let help : Q.signature_help = {signatures =
    [{label = "frontend_signature(argument)"; documentation = []; parameters = []; active_parameter = None}]
    ; active_signature = 0; active_parameter = None} in
  let deliver (q : Q.request) =
    !emit (Query_result {token = q.token; cursor = q.cursor; kind = q.kind
      ; source = "fake"; result = Signature_result (Some help)}) in
  deliver (List.hd_exn !requests);
  let%bind () = settle () in
  Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
  assert (not (String.is_substring [%expect.output] ~substring:"frontend_signature"));
  deliver (List.last_exn !requests);
  let%bind () = settle () in
  Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
  assert (String.is_substring [%expect.output] ~substring:"frontend_signature(argument)");
  (* No answer to the next request: typing still advances and submits another. *)
  send 'b';
  let%bind () = settle () in
  send 'c';
  let%bind () = settle () in
  assert (List.length !requests = 4);
  assert (match (List.last_exn !requests).kind with
    | Signature_help {character = Some "c"; retrigger = true; _} -> true | _ -> false);
  Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
  assert (String.is_substring [%expect.output] ~substring:"(abc");
  Bonsai_term_test.send_event handle (Key_press {key = ASCII 'k'; mods = [Ctrl]});
  let%bind () = settle () in
  assert (List.length !requests = 5);
  assert (match (List.last_exn !requests).kind with
    | Signature_help {automatic = false; character = None; retrigger = false} -> true
    | _ -> false);
  [%expect {|
    (cursor (((position ((x 7) (y 1))) (kind Bar))))
    (cursor (((position ((x 7) (y 1))) (kind Bar))))
    |}];
  Ches_source.Source.stop source;
  print_endline "automatic source counts, stale result, retrigger and nonblocking edits passed";
  [%expect {| automatic source counts, stale result, retrigger and nonblocking edits passed |}];
  return ()
;;
