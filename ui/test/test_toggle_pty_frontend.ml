open! Core
open! Async
open Bonsai_term
open Ches_ui

module Expect_test_config = Async.Expect_test_config

let%expect_test "frontend timeout turns deliver deferred terminal bytes without another key" =
  let terminal = Terminal_host.create () in
  Monitor.protect
    (fun () ->
      let text = Ches_core.Text_buffer.of_string "seed"
        |> Result.map_error ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum
        |> Result.ok_or_failwith in
      let controller = Ches_app.Controller.create
          (Ches_core.Editor.create ~cell_width:Ches_screen.Cell_map.width text) in
      let handle = Bonsai_term_test.create_handle ~initial_dimensions:{ width = 120; height = 40 }
          (Editor_view.app ~terminal ~bare:true ~smear_enabled:false controller
             ~exit:(fun () -> Effect.Ignore)) in
      let send key = Bonsai_term_test.send_event handle (Key_press { key; mods = [] }) in
      let type_ s = String.iter s ~f:(fun c -> send (ASCII c)) in
      let output () =
        Bonsai_test.Handle.recompute_view handle;
        Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
        [%expect.output] in
      let wait needle =
        let rec loop () =
          if String.is_substring (output ()) ~substring:needle then return ()
          else let%bind () = Clock_ns.after (Time_ns.Span.of_ms 5.) in loop () in
        let%map result = Clock_ns.with_timeout (Time_ns.Span.of_sec 5.) (loop ()) in
        match result with
        | `Result () -> ()
        | `Timeout -> failwith ("terminal frontend never displayed " ^ needle) in
      type_ " /";
      (* Paste bypasses shortcuts and starts a byte-reporting child. Split the
         readiness marker so the shell's initial command echo cannot satisfy it. *)
      Bonsai_term_test.send_event handle (Paste `Start);
      type_ "stty -echo -icanon min 1 time 0; printf 'CLOCK_%s\\n' READY; od -An -tu1 -w1";
      Bonsai_term_test.send_event handle (Paste `End);
      send Enter;
      let%bind () = wait "CLOCK_READY" in
      let tick ms =
        Bonsai_test.Handle.advance_clock_by handle (Time_ns.Span.of_ms ms);
        for _ = 1 to 3 do Bonsai_test.Handle.recompute_view handle done in
      type_ " ";
      tick 221.;
      let%bind () = wait "  32" in
      type_ "2";
      tick 221.;
      let%bind () = wait "  50" in
      type_ "j";
      tick 170.;
      let%bind () = wait " 106" in
      ignore (output () : string);
      print_endline "smear-off timer delivered Space, digit and jk-prefix bytes through PTY effects";
      [%expect {| smear-off timer delivered Space, digit and jk-prefix bytes through PTY effects |}];
      return ())
    ~finally:(fun () -> Terminal_host.shutdown terminal)
;;
