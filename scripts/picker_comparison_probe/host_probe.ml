(* One real-root cold/query observation, actual Async host and frame construction.
   Eager rendering per injected batch; excludes terminal transport and disk preview. *)
open! Core
open! Async
open Ches_screen
module Runtime = Ches_file_picker_host.Runtime
module Interaction = Ches_file_picker.Interaction
module Model = Ches_file_picker.Model

let now () = Or_error.ok_exn Core_unix.Clock.gettime Core_unix.Clock.Monotonic
let ms start = Int63.to_float (Int63.( - ) (now ()) start) /. 1e6
let width = 160
let height = 40
let () =
  let root = match Sys.get_argv () with
    | [| _; root |] -> root
    | _ -> failwith "Usage: host_probe.exe ABSOLUTE_ROOT" in
  Thread_safe.block_on_async_exn (fun () ->
    let runtime = Runtime.create () in
    let controller = Ches_app.Controller.create
      (Ches_core.Editor.create ~cell_width:Cell_map.width Ches_core.Text_buffer.empty) in
    let state = ref (Ui_state.create controller) in
    let cache = Frame.Cache.create () and builds = ref 0 in
    let session () = File_picker_tile.session (Option.value_exn (Ui_state.file_picker !state)) in
    let render () = ignore (Frame.Cache.get cache !state ~width ~height ~draw_base:(fun frame ->
      incr builds; frame.Frame.rows) : Frame.t * Frame.Span.t list list) in
    let apply inputs = state := fst (Frame.Cache.apply_inputs cache !state ~width ~height inputs) in
    let drain name start =
      let batches = ref 0 and render_ms = ref 0. and max_inject = ref 0. in
      let before_builds = !builds in
      let%bind result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10)
        (Runtime.pump runtime ~current:(fun () -> !state) ~inject:(fun inputs ->
          let turn = now () in
          apply inputs;
          let draw = now () in render (); render_ms := !render_ms +. ms draw;
          max_inject := Float.max !max_inject (ms turn); incr batches; return ())) in
      (match result with `Timeout -> failwith "host probe timed out" | `Result () -> ());
      let t = session () in
      Stdlib.Printf.printf "phase=%s root=%S total_ms=%.3f injected_batches=%d base_builds=%d frame_sum_ms=%.3f max_apply_and_frame_ms=%.3f discovered=%d matches=%d prepared=%d\n%!"
        name root (ms start) !batches (!builds - before_builds) !render_ms !max_inject
        (Model.discovered_count (Interaction.model t))
        (Model.result_count (Interaction.model t)) (Interaction.prepared_count t);
      return () in
    let opening name =
      let start = now () in
      state := Runtime.open_picker runtime !state ~root ~width ~height |> Or_error.ok_exn;
      let t = session () in
      Stdlib.Printf.printf "phase=%s immediate_open_ms=%.3f available=%d cached_hits=%d refresh_pending=%b indexed=%d prepared=%d cache_charge_bytes=%d\n%!"
        name (ms start) (Model.result_count (Interaction.model t)) (Runtime.cache_hits runtime)
        (Interaction.refreshing t) (Interaction.indexed_count t) (Interaction.prepared_count t) (Runtime.cache_bytes runtime);
      render (); drain name start in
    let%bind () = opening "cold-open" in
    let%bind () = Deferred.List.iter ~how:`Sequential
      [ "edit-m", Ches_input.Key.char 'm'; "extend-mo", Ches_input.Key.char 'o'
      ; "backspace-m", Ches_input.Key.Backspace ] ~f:(fun (name, key) ->
        let start = now () in apply [ Ui_state.Input.Key key ]; render (); drain name start) in
    let start = now () in
    apply [ Ui_state.Input.Key (Ches_input.Key.Ctrl 'n') ]; render ();
    Stdlib.Printf.printf "phase=movement apply_and_frame_ms=%.3f\n%!" (ms start);
    apply [ Ui_state.Input.Key Ches_input.Key.Escape ];
    let%bind result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (Runtime.finished runtime) in
    (match result with `Result () -> () | `Timeout -> failwith "first cleanup timeout");
    let%bind () = opening "reopen-refresh" in
    assert (not (Interaction.acceptance_blocked (session ())));
    apply [ Ui_state.Input.Key Ches_input.Key.Escape ];
    let%map result = Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (Runtime.finished runtime) in
    match result with
    | `Result () -> Stdlib.Printf.printf "phase=cleanup finished=true\n%!"
    | `Timeout -> failwith "host cleanup timed out")
