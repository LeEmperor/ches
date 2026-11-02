open! Core
open Bonsai_term
open Ches_ui

(* A closed PTY host keeps these event-routing tests deterministic: they exercise
   the production app and its clock without starting shells or receiving output. *)
let create ?(smear_enabled = false) () =
  let text = Ches_core.Text_buffer.of_string "seed"
    |> Result.map_error ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum
    |> Result.ok_or_failwith in
  let controller = Ches_app.Controller.create
      (Ches_core.Editor.create ~cell_width:Ches_screen.Cell_map.width text) in
  let terminal = Terminal_host.create () in
  Terminal_host.stop terminal;
  Bonsai_term_test.create_handle ~initial_dimensions:{ width = 120; height = 40 }
    (Editor_view.app ~terminal ~bare:true ~smear_enabled controller
       ~exit:(fun () -> Effect.Ignore))
;;

let send handle ?(mods = []) key =
  Bonsai_term_test.send_event handle (Key_press { key; mods })
;;

let type_ handle s = String.iter s ~f:(fun c -> send handle (ASCII c))
let contains s substring = String.is_substring s ~substring

let advance handle ms =
  Bonsai_test.Handle.advance_clock_by handle (Time_ns.Span.of_ms ms);
  for _ = 1 to 3 do Bonsai_test.Handle.recompute_view handle done
;;

let%expect_test "Insert toggles restore editor mode and route consecutive events using current capture" =
  let handle = create () in
  let output () =
    Bonsai_test.Handle.recompute_view handle;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    [%expect.output] in
  (* No display between editor Insert, terminal Insert, and editor Insert again.
     A handler closing over the last displayed capture state loses these keys. *)
  type_ handle "iA / /Z";
  let view = output () in
  assert (contains view "AZseed");
  assert (contains view "(kind Bar)");
  assert (not (contains view "Tile Term 1"));
  type_ handle "2 /";
  assert (contains (output ()) "Tile Term 2");
  type_ handle "3 /";
  assert (contains (output ()) "Tile Term 3");
  type_ handle "3 /B";
  let view = output () in
  assert (contains view "AZBseed");
  assert (contains view "(kind Bar)");
  assert (not (contains view "Tile Term 3"));
  send handle Escape;
  type_ handle " / /";
  let view = output () in
  assert (contains view "(kind Block)");
  assert (not (contains view "Tile Term 3"));
  print_endline "same-frame capture, numbered switching and Insert/Normal restoration passed";
  [%expect {| same-frame capture, numbered switching and Insert/Normal restoration passed |}]
;;

let%expect_test "standalone editor spaces and digits expire on the controlled frontend timer" =
  List.iter [ false; true ] ~f:(fun smear_enabled ->
    let handle = create ~smear_enabled () in
    let output () =
      Bonsai_test.Handle.recompute_view handle;
      Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
      [%expect.output] in
    type_ handle "iX ";
    assert (contains (output ()) "Xseed");
    advance handle 170.;
    assert (contains (output ()) "Xseed");
    advance handle 51.;
    assert (contains (output ()) "X seed");
    type_ handle "42";
    assert (not (contains (output ()) "X 42seed"));
    advance handle 221.;
    assert (contains (output ()) "X 42seed");
    (* A long idle before the next event must not date it with a stale render's
       time or the wall clock: a fresh prefix still completes immediately. *)
    advance handle 10_000.;
    type_ handle " /";
    assert (contains (output ()) "Tile Term 1");
    type_ handle " /Y";
    let view = output () in
    assert (contains view "X 42Yseed"));
  print_endline "200ms editor prefix timeout uses the event clock with smear on and off";
  [%expect {| 200ms editor prefix timeout uses the event clock with smear on and off |}]
;;

let%expect_test "terminal timeout and full-fidelity modifiers preserve plain-only toggles" =
  let handle = create () in
  let output () =
    Bonsai_test.Handle.recompute_view handle;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    [%expect.output] in
  type_ handle "i /";
  assert (contains (output ()) "Tile Term 1");
  type_ handle " ";
  advance handle 221.;
  type_ handle "/";
  assert (contains (output ()) "Tile Term 1");
  type_ handle " ";
  send handle ~mods:[ Meta ] (ASCII '/');
  assert (contains (output ()) "Tile Term 1");
  send handle ~mods:[ Meta ] (ASCII ' ');
  type_ handle "/";
  assert (contains (output ()) "Tile Term 1");
  send handle (Function 5);
  send handle ~mods:[ Ctrl ] (Arrow `Left);
  type_ handle " /Q";
  let view = output () in
  assert (not (contains view "Tile Term 1"));
  assert (contains view "Qseed");
  assert (contains view "(kind Bar)");
  print_endline "terminal expiry, Meta/full-fidelity keys and plain toggle passed";
  [%expect {| terminal expiry, Meta/full-fidelity keys and plain toggle passed |}]
;;
