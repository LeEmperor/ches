(* Explicit, bounded headless lifecycle probe. No Async/terminal latency claim. *)
open! Core
open Ches_file_picker
module Tile = Ches_screen.File_picker_tile

let now () = Or_error.ok_exn Core_unix.Clock.gettime Core_unix.Clock.Monotonic
let ms start = Int63.to_float (Int63.( - ) (now ()) start) /. 1e6
let timed f = let start = now () in let value = f () in value, ms start
let drain t =
  let start = now () in
  let turns = ref 0 and maximum = ref 0. and last = ref 0. in
  let snapshot = ref 0. and score = ref 0. and output = ref 0. in
  while Interaction.busy t do
    let phase = Interaction.work_phase t in
    let (), elapsed = timed (fun () -> Interaction.work t ~budget:128) in
    (match phase with
     | `Snapshot -> snapshot := !snapshot +. elapsed
     | `Score -> score := !score +. elapsed
     | `Output -> output := !output +. elapsed
     | `Reuse -> ()
     | `Idle -> ());
    incr turns; maximum := Float.max !maximum elapsed; last := elapsed
  done;
  ms start, !turns, !maximum, !last, !snapshot, !score, !output

let report count name t =
  let total, turns, maximum, last, snapshot, score, output = drain t in
  printf "n=%d phase=%s query=%S total_ms=%.3f turns=%d max_turn_ms=%.3f publication_turn_ms=%.3f results=%d prepared=%d snapshot_ms=%.3f score_ms=%.3f output_ms=%.3f alignments=%d examined=%d cache_hits=%d narrowed_jobs=%d cache_entries=%d cache_charge_bytes=%d evictions=%d\n%!"
    count name (Interaction.query t) total turns maximum last
    (Model.result_count (Interaction.model t)) (Interaction.prepared_count t)
    snapshot score output (Model.For_testing.alignment_count (Interaction.model t))
    (Interaction.last_examined_count t) (Interaction.cache_hits t) (Interaction.narrowed_count t)
    (Interaction.cache_entries t) (Interaction.cache_bytes t) (Interaction.cache_evictions t)

let verify_oracle candidates =
  let module F = Ches_palette.Fuzzy in
  let candidates = List.take candidates 64 @
    List.map [ "界/模型.ml"; "café/École.ml"; "odd/line\nfile.ml"; "dir/a\\\xffb.ml" ]
      ~f:(fun relative_path -> Model.Candidate.create ~root:"/bench" ~relative_path |> Or_error.ok_exn) in
  let raw = List.map candidates ~f:(fun c ->
    let path = Model.Candidate.relative_path c in
    let start = match String.rindex path '/' with None -> 0 | Some i -> i + 1 in
    c, [ { F.Field.tag = start; text = String.drop_prefix path start; weight = 150 }
       ; { F.Field.tag = 0; text = path; weight = 100 } ]) in
  let prepared = Search.prepare candidates in
  let queries = [ ""; "m"; "mo"; "model"; "MODE"; "src mod"; "模型"; "É"; "�"; "\\"; "zzzz" ] in
  List.iter queries ~f:(fun query ->
    let expected = F.rank ~policy:Loose_subsequence ~query raw |> List.map ~f:(fun r ->
      let raw_positions = List.concat_map r.F.Match.positions ~f:(fun (field, offsets) ->
        List.map offsets ~f:(( + ) field.F.Field.tag)) in
      { Model.Query_result.candidate = r.item; score = r.score
      ; positions = Model.Candidate.display_positions r.item ~raw_positions }) in
    assert (String.equal (Sexp.to_string [%sexp (expected : Model.Query_result.t list)])
      (Sexp.to_string [%sexp (Search.rank ~query prepared : Model.Query_result.t list)])));
  printf "oracle_candidates=%d queries=%d scores_order_positions=equal\n%!" (List.length candidates) (List.length queries)

let run count =
  let candidates, creation = timed (fun () -> List.init count ~f:(fun i ->
    let directory = [| "src"; "test"; "lib"; "docs"; "vendor" |].(i % 5) in
    let basename = [| "model.ml"; "file_picker.ml"; "controller.ml"; "README.md"; "test_search.ml" |].(i / 5 % 5) in
    Model.Candidate.create ~root:"/bench"
      ~relative_path:(sprintf "%s/package_%04d/component_%02d/%s" directory (i / 25) (i % 25) basename)
    |> Or_error.ok_exn)) in
  printf "n=%d candidate_creation_ms=%.3f\n%!" count creation;
  if count = 10_000 then verify_oracle candidates;
  let discovery : Model.Discovery.t =
    { request = { run_id = Model.Run_id.of_int 1; root = "/bench" }
    ; candidates; status = Complete { truncated = false } } in
  Gc.full_major ();
  let before = (Gc.stat ()).live_words in
  let picker = Tile.create ~token:() ~discovery in
  let t = Tile.session picker in
  report count "cold-complete-snapshot" t;
  Gc.full_major ();
  printf "n=%d cold_live_delta_mib=%.3f\n%!" count
    (Float.of_int ((Gc.stat ()).live_words - before) *. 8. /. 1048576.);
  let render phase =
    let _, elapsed = timed (fun () -> Tile.render picker ~width:160 ~rows:36) in
    printf "n=%d phase=%s render_ms=%.3f alignments=%d alignment_cache=%d alignment_charge_bytes=%d\n%!" count phase elapsed
      (Model.For_testing.alignment_count (Interaction.model t))
      (Model.For_testing.alignment_cache_size (Interaction.model t))
      (Model.For_testing.alignment_cache_bytes (Interaction.model t)) in
  render "blank";
  let _, movement = timed (fun () -> Tile.update picker ~rows:36 Next) in
  printf "n=%d phase=blank-next update_and_fit_ms=%.3f\n%!" count movement;
  render "blank-next";
  List.iter [ "edit-m", Ches_palette.Palette.Event.Paste "m"
            ; "extend-mo", Paste "o"; "extend-model", Paste "del"
            ; "backspace-mode", Backspace; "backspace-mod", Backspace
            ; "repeat-model", Paste "el"
            ; "cached-backspace-mode", Backspace; "cached-backspace-mod", Backspace
            ; "cached-repeat-model", Paste "el"
            ; "narrow-extra-token", Paste " m"; "narrow-token-extension", Paste "l"
            ; "semantic-repeat-model", Delete_word; "clear", Delete_word ]
    ~f:(fun (name, event) ->
      let (), update = timed (fun () -> Tile.update picker ~rows:36 event) in
      printf "n=%d phase=%s update_and_fit_ms=%.3f\n%!" count name update;
      report count name t; render name;
      if String.equal name "edit-m" then (
        Gc.full_major ();
        printf "n=%d first_query_live_delta_mib=%.3f prepared_payload_bytes=%d\n%!" count
          (Float.of_int ((Gc.stat ()).live_words - before) *. 8. /. 1048576.)
          (Interaction.prepared_payload_bytes t)));
  Gc.full_major ();
  printf "n=%d final_lru_live_delta_mib=%.3f cache_charge_bytes=%d cache_entries=%d\n%!" count
    (Float.of_int ((Gc.stat ()).live_words - before) *. 8. /. 1048576.)
    (Interaction.cache_bytes t) (Interaction.cache_entries t);
  Interaction.cancel t ~release:ignore;
  let reopened = Interaction.create ~token:() ~discovery in
  report count "reopen-complete-snapshot" reopened;
  Interaction.cancel reopened ~release:ignore;
  (* Actual delta/persistent-set protocol, one work turn per incoming batch.
     No filesystem fixture/rg here. Both blank and fixed model query make progress. *)
  let update = ref (Model.Discovery.Update.initial discovery.request) in
  let make () =
    let t = Interaction.create ~token:() ~discovery:{ discovery with candidates = []; status = Loading } in
    assert (Interaction.install_update t !update); t in
  let blank = make () and streamed = make () in
  Interaction.update streamed (Paste "model");
  let rebuild = ref 0. and install_work = ref 0. and batches = ref 0 in
  List.iter (List.chunks_of candidates ~length:128) ~f:(fun batch ->
    incr batches;
    let next, elapsed = timed (fun () -> Model.Discovery.Update.append !update ~status:Partial batch) in
    update := next;
    assert (not (Model.Discovery.Candidates.materialized next.candidates));
    rebuild := !rebuild +. elapsed;
    let (), elapsed = timed (fun () ->
      assert (Interaction.install_update streamed next && Interaction.install_update blank next);
      Interaction.work blank ~budget:128;
      Interaction.work streamed ~budget:128) in
    install_work := !install_work +. elapsed;
    assert (Interaction.scored_count streamed = Model.Discovery.Candidates.length next.candidates));
  update := Model.Discovery.Update.append !update ~status:(Complete { truncated = false }) [];
  assert (Interaction.install_update streamed !update && Interaction.install_update blank !update);
  printf "n=%d phase=stream-delta batches=%d persistent_set_ms=%.3f two_query_install_work_ms=%.3f prepared_before_final=%d scored=%d blank_prepared=%d busy=%b list_materialized=%b\n%!"
    count !batches !rebuild !install_work (Interaction.prepared_count streamed)
    (Interaction.scored_count streamed) (Interaction.prepared_count blank)
    (Interaction.busy streamed) (Model.Discovery.Candidates.materialized !update.candidates);
  report count "stream-final-drain" streamed;
  let saved, capture_ms = timed (fun () -> Option.value_exn (Interaction.snapshot streamed)) in
  let request = { discovery.request with run_id = Model.Run_id.of_int 2 } in
  let initial = Model.Discovery.Update.initial request in
  let reopened = Interaction.create ~token:() ~discovery:{ request; candidates = []; status = Loading } in
  let (), restore_ms = timed (fun () -> assert (Interaction.restore_snapshot reopened saved initial)) in
  printf "n=%d phase=reopen-cache capture_ms=%.3f restore_ms=%.3f visible=%d prepared=%d indexed=%d charge_bytes=%d blocked=%b\n%!"
    count capture_ms restore_ms (Model.result_count (Interaction.model reopened)) (Interaction.prepared_count reopened)
    (Interaction.indexed_count reopened) (Interaction.Snapshot.bytes saved) (Interaction.acceptance_blocked reopened);
  let fresh = ref initial in
  List.iter (List.chunks_of candidates ~length:128) ~f:(fun batch ->
    fresh := Model.Discovery.Update.append !fresh ~status:Partial batch;
    assert (Interaction.install_update reopened !fresh));
  fresh := Model.Discovery.Update.append !fresh ~status:(Complete { truncated = false }) [];
  let (), commit_ms = timed (fun () -> assert (Interaction.install_update reopened !fresh)) in
  printf "n=%d phase=reopen-unchanged commit_ms=%.3f indexed=%d prepared=%d scored=%d blocked=%b\n%!"
    count commit_ms (Interaction.indexed_count reopened) (Interaction.prepared_count reopened)
    (Interaction.scored_count reopened) (Interaction.acceptance_blocked reopened);
  Interaction.cancel reopened ~release:ignore;
  Interaction.cancel streamed ~release:ignore;
  Interaction.cancel blank ~release:ignore

let () = List.iter [ 10_000; 50_000 ] ~f:run
