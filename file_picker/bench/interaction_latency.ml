(* Single-run scheduling/cache probe; not terminal or p99 latency. *)
open! Core
open Ches_file_picker

let now () = Or_error.ok_exn Core_unix.Clock.gettime Core_unix.Clock.Monotonic
let elapsed start = Int63.to_float (Int63.( - ) (now ()) start) /. 1e6

let drain t =
  let start = now () in
  let max_ms = ref 0. in
  let turns = ref 0 in
  while Interaction.busy t do
    let turn = now () in
    Interaction.work t ~budget:128;
    max_ms := Float.max !max_ms (elapsed turn);
    incr turns
  done;
  elapsed start, !max_ms, !turns
;;

let () =
  List.iter [ 1_000; 10_000; 50_000 ] ~f:(fun count ->
    let candidates = List.init count ~f:(fun i ->
      let directory = [| "src"; "test"; "lib"; "docs"; "vendor" |].(i % 5) in
      let basename = [| "model.ml"; "file_picker.ml"; "controller.ml"; "README.md"; "test_search.ml" |].(i / 5 % 5) in
      Model.Candidate.create ~root:"/bench"
        ~relative_path:(sprintf "%s/package_%04d/component_%02d/%s" directory (i / 25) (i % 25) basename)
      |> Or_error.ok_exn) in
    let discovery : Model.Discovery.t =
      { request = { run_id = Model.Run_id.of_int 1; root = "/bench" }
      ; candidates; status = Complete { truncated = false } } in
    Gc.full_major ();
    let before = (Gc.stat ()).live_words in
    let t = Interaction.create ~token:() ~discovery in
    assert (Interaction.prepared_count t = 0);
    let total, max_turn, turns = drain t in
    Gc.full_major ();
    let live = (Gc.stat ()).live_words - before in
    printf "count=%d initial_total_ms=%.3f max_work_ms=%.3f turns=%d retained_mib=%.2f prepared=%d\n%!"
      count total max_turn turns (Float.of_int live *. 8. /. 1048576.) (Interaction.prepared_count t);
    List.iter [ "m"; "model"; "src mod"; "zzzzzz" ] ~f:(fun query ->
      Interaction.update t Ches_palette.Palette.Event.Delete_word;
      while not (String.is_empty (Interaction.query t)) do
        Interaction.update t Delete_word
      done;
      let start = now () in
      Interaction.update t (Paste query);
      let update_ms = elapsed start in
      let total, max_turn, turns = drain t in
      assert (Interaction.prepared_count t = count);
      printf "count=%d query=%S update_ms=%.3f work_total_ms=%.3f max_work_ms=%.3f turns=%d matches=%d prepared=%d\n%!"
        count query update_ms total max_turn turns
        (List.length (Model.results (Interaction.model t))) (Interaction.prepared_count t));
    Interaction.cancel t ~release:ignore)
;;
