open! Core
open! Async
module S = Ches_screen.Ui_state
module M = Ches_completion.Model

let main () =
  let raw = "\n" ^ String.concat (List.init 400000 ~f:(fun i -> sprintf "alpha%06d padding\n" i)) in
  let text = Ches_core.Text_buffer.of_string raw |> Result.ok |> Option.value_exn in
  let controller = Ches_app.Controller.create (Ches_core.Editor.create ~path:"/bench-index"
      ~cell_width:Ches_screen.Cell_map.width text) in
  let ui = S.create ~tiles_visible:false controller in
  let inputs = List.map (String.to_list "ial") ~f:(fun c -> S.Input.Key (Ches_input.Key.char c)) in
  let start = Time_ns.now () in
  let (ui, _), scanned = M.Buffer_words.For_testing.measure (fun () ->
    S.apply_all ui ~width:80 ~height:24 inputs) in
  let query = Time_ns.diff (Time_ns.now ()) start in
  let r = snd (S.take_word_index_request ui) |> Option.value_exn in
  let host = Ches_ui.Word_index_host.create () in
  let ticks = ref 0 and max_gap = ref Time_ns.Span.zero in
  let finished = ref false in
  let rec heartbeat previous =
    let%bind () = Scheduler.yield () in
    let now = Time_ns.now () in
    max_gap := Time_ns.Span.max !max_gap (Time_ns.diff now previous);
    incr ticks;
    if !finished then return () else heartbeat now in
  let start = Time_ns.now () in
  don't_wait_for (heartbeat start);
  Ches_ui.Word_index_host.follow host (Some r);
  let%bind reply = Ches_ui.Word_index_host.next host in
  let elapsed = Time_ns.diff (Time_ns.now ()) start in
  finished := true;
  let r, words = Option.value_exn reply in
  let ready = S.receive_word_index ui r words in
  printf "bytes=%d first_query_ms=%.3f tokenized=%d build_ms=%.3f scheduler_ticks=%d max_gap_ms=%.3f candidates=%d\n"
    (String.length raw) (Time_ns.Span.to_ms query) scanned (Time_ns.Span.to_ms elapsed)
    !ticks (Time_ns.Span.to_ms !max_gap) (List.length (S.completion_candidates ready));
  Ches_ui.Word_index_host.stop host;
  return ()

let () =
  don't_wait_for (let%bind () = main () in Shutdown.exit 0);
  never_returns (Scheduler.go ())
