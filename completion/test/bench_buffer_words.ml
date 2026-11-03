(* Run explicitly: dune exec -j6 completion/test/bench_buffer_words.exe
   CPU timings isolate index work from Text_buffer's deliberate full-string blit. *)
open! Core
open Ches_core
open Ches_completion.Model
module B = Text_buffer
module W = Buffer_words

let text s = B.of_string s |> Result.ok |> Option.value_exn
let timed f =
  let start = Stdlib.Sys.time () in
  let result = f () in
  result, (Stdlib.Sys.time () -. start) *. 1000.
;;
let run ~distinct size =
  let source =
    if distinct then
      String.concat (List.init (size / 12) ~f:(fun i -> sprintf "word%07d " i))
    else String.concat (List.init (size / 12) ~f:(fun _ -> "alpha value "))
  in
  let base = text ("wo al " ^ source) in
  Stdlib.Gc.full_major ();
  let before = (Stdlib.Gc.stat ()).live_words in
  let (index, scanned), create_ms = timed (fun () ->
    W.For_testing.measure (fun () -> W.create base)) in
  Stdlib.Gc.full_major ();
  let retained = ((Stdlib.Gc.stat ()).live_words - before) * 8 in
  let snapshots =
    let rec loop t i acc =
      if i = 100 then List.rev acc else
        let t = B.replace t ~pos:(B.length t / 2) ~len:0 "x"
          |> Result.ok |> Option.value_exn in
        loop t (i + 1) (t :: acc)
    in
    loop base 0 []
  in
  let (_, update_bytes), update_ms = timed (fun () -> W.For_testing.measure (fun () ->
    List.fold snapshots ~init:index ~f:W.update)) in
  let _, query_ms = timed (fun () ->
    for _ = 1 to 1000 do
      ignore (Sys.opaque_identity (W.candidates index ~text:base ~cursor:(if distinct then 2 else 5) ~limit:100)
        : Candidate.t list)
    done) in
  printf "%s bytes=%d create_ms=%.3f scanned=%d retained_index_bytes=%d update_us=%.3f scanned_per_update=%.1f query_us=%.3f\n%!"
    (if distinct then "distinct" else "repeated") (B.length base) create_ms scanned retained
    (update_ms *. 10.) (Float.of_int update_bytes /. 100.) query_ms
;;

let () =
  List.iter [ 128 * 1024; 1024 * 1024; 4 * 1024 * 1024 ] ~f:(fun size ->
    run ~distinct:false size;
    run ~distinct:true size)
;;
