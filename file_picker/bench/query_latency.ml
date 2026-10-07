(* Headless discovery-independent probe, not input-to-screen timing. *)
open! Core
open Ches_file_picker
module Fuzzy = Ches_palette.Fuzzy

let now = Or_error.ok_exn Core_unix.Clock.gettime
let samples = 10

let timed f =
  let start = now Monotonic in
  let value = f () in
  let elapsed = Int63.to_float (Int63.( - ) (now Monotonic) start) /. 1e6 in
  value, elapsed
;;

let fields candidate =
  let path = Model.Candidate.relative_path candidate in
  [ { Fuzzy.Field.tag = (); text = Filename.basename path; weight = 150 }
  ; { Fuzzy.Field.tag = (); text = path; weight = 100 }
  ]
;;

let run name candidates =
  let raw = List.map candidates ~f:(fun c -> c, fields c) in
  Gc.full_major ();
  let before = Gc.stat () in
  let prepared, preparation_ms = timed (fun () -> Search.prepare candidates) in
  Gc.full_major ();
  let after = Gc.stat () in
  printf "dataset=%s count=%d path_bytes=%d preparation_ms=%.3f retained_words=%d\n%!"
    name (List.length candidates)
    (List.sum (module Int) candidates ~f:(fun c -> String.length (Model.Candidate.relative_path c)))
    preparation_ms (after.live_words - before.live_words);
  List.iter [ ""; "m"; "model"; "src mod"; "sfp"; "zzzzzz" ] ~f:(fun query ->
    let expected = Fuzzy.rank ~policy:Loose_subsequence ~query raw in
    let cached = Search.rank ~query prepared in
    assert (List.equal String.equal
      (List.map expected ~f:(fun r -> Model.Candidate.path r.Fuzzy.Match.item))
      (List.map cached ~f:(fun r -> Model.Candidate.path r.Model.Query_result.candidate)));
    List.iter [ "uncached", (fun () -> List.length (Fuzzy.rank ~policy:Loose_subsequence ~query raw))
              ; "cached+display", (fun () -> List.length (Search.rank ~query prepared)) ]
      ~f:(fun (mode, f) ->
        ignore (f () : int);
        Gc.full_major ();
        let allocated = Gc.allocated_bytes () in
        let times = Array.init samples ~f:(fun i ->
          let count, ms = timed f in
          assert (count = List.length expected);
          printf "sample dataset=%s query=%S mode=%s index=%d ms=%.3f\n" name query mode i ms;
          ms) in
        let bytes = (Gc.allocated_bytes () -. allocated) /. Float.of_int samples in
        Array.sort times ~compare:Float.compare;
        printf "summary dataset=%s query=%S mode=%s matches=%d median_ms=%.3f max_ms=%.3f allocated_bytes=%.0f\n%!"
          name query mode (List.length expected) times.(samples / 2) times.(samples - 1) bytes))
;;

let candidate path = Model.Candidate.create ~root:"/bench" ~relative_path:path |> Or_error.ok_exn

let () =
  (* Explicit argv paths permit a real project's NUL-delimited rg output without
     discovery inside the timed section. Default is a deterministic source tree. *)
  let args = Sys.get_argv () in
  if Array.length args > 1
  then (
    let bytes = In_channel.read_all args.(1) in
    let paths = String.split bytes ~on:'\000' |> List.filter ~f:(Fn.non String.is_empty) in
    run "real-project" (List.map paths ~f:candidate));
  List.iter [ 1_000; 10_000; 50_000 ] ~f:(fun n ->
    let candidates = List.init n ~f:(fun i ->
      let directory = [| "src"; "test"; "lib"; "docs"; "vendor" |].(i % 5) in
      let basename = [| "model.ml"; "file_picker.ml"; "controller.ml"; "README.md"; "test_search.ml" |].(i / 5 % 5) in
      candidate (sprintf "%s/package_%04d/component_%02d/%s" directory (i / 25) (i % 25) basename)) in
    run (sprintf "synthetic-%d" n) candidates)
;;
