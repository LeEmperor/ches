open! Core
open! Async
open Bonsai_test
open Bonsai_term
open Ches_screen
module Expect_test_config = Async.Expect_test_config

let%expect_test "shipped line command chains yielded turns, accepts dirty text and reveals the target" =
  let contents = String.concat ~sep:"\n"
    (List.init 5000 ~f:(fun n -> if n = 4999 then "\t界é final" else sprintf "row %d" n)) in
  let text = Ches_core.Text_buffer.of_string contents |> Result.map_error
    ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
  let controller = Ches_app.Controller.create
    (Ches_core.Editor.create ~cell_width:Cell_map.width text) in
  let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 100; height = 30 }
    (Ches_ui.Editor_view.app controller ~exit:(fun () -> Effect.Ignore)) in
  let send key = Bonsai_term_test.send_event handle (Key_press { key; mods = [] }) in
  let type_ s = String.iter s ~f:(fun c -> send (ASCII c)) in
  let output () =
    Handle.recompute_view handle;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    [%expect.output] in
  let rec wait_for predicate =
    let current = output () in
    if predicate current then return current
    else let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in wait_for predicate in
  let wait predicate =
    let%map result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (wait_for predicate) in
    match result with `Result s -> s | `Timeout -> failwith "line frontend did not settle" in
  type_ "GAUNSAVEDneedle";
  send Escape;
  type_ "gg fl";
  (* Cancel a still-pending turn and reopen: the old turn cannot prepare the new
     session, and its completion must restart the one scheduling chain. *)
  send Escape;
  type_ " flneedle";
  let%bind view = wait (fun s -> String.is_substring s ~substring:"5000"
    && String.is_substring s ~substring:"UNSAVEDneedle"
    && not (String.is_substring s ~substring:"Filtering...")) in
  assert (String.is_substring view ~substring:"Document lines");
  send Enter;
  let%bind view = wait (fun s -> String.is_substring s ~substring:"UNSAVEDneedle"
    && not (String.is_substring s ~substring:"Document lines")) in
  assert (not (String.is_substring view ~substring:"Filtering..."));
  (* A fresh command via the catalog is real too, not a test-injected opener. *)
  type_ " ccSearch current document lines";
  send Enter;
  let%bind _ = wait (fun s -> String.is_substring s ~substring:"Document lines"
    && not (String.is_substring s ~substring:"Filtering...")) in
  send Escape;
  let%bind view = wait (fun s -> not (String.is_substring s ~substring:"Document lines")) in
  assert (String.is_substring view ~substring:"UNSAVEDneedle");
  ignore ([%expect.output] : string);
  print_endline "live binding/catalog, dirty 5k-line async search, replacement and viewport reveal passed";
  [%expect {| live binding/catalog, dirty 5k-line async search, replacement and viewport reveal passed |}];
  return ()
;;
