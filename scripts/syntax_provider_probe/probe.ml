(* Explicit resource/latency observation, not a test or editor input path.
   Forced GC is for this probe only; native allocations are not accounted for by
   the binding. RSS is Linux-specific and is not a leak-freedom assertion. *)
open Ches_highlight
open Ches_highlight_ocaml

let rss_kib () =
  let channel = open_in "/proc/self/status" in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    let rec loop () =
      let line = input_line channel in
      if String.starts_with ~prefix:"VmRSS:" line
      then Scanf.sscanf line "VmRSS: %d kB" Fun.id
      else loop ()
    in
    loop ())
;;

let sample () =
  Gc.full_major ();
  Gc.compact ();
  rss_kib ()
;;

let observe name language line =
  let source = String.concat "" (List.init 500 (fun _ -> line)) in
  let provider = Provider.create ~language in
  let key = Provider.key provider ~document:(Snapshot.Document_id.create ()) ~revision:0 in
  let expected = ref None in
  Printf.printf "%s: %d bytes, RSS before %d KiB\n%!" name (String.length source) (sample ());
  for batch = 1 to 4 do
    let started = Unix.gettimeofday () in
    for _ = 1 to 50 do
      let result = Provider.highlight provider ~key ~source in
      (match result.status with
       | Highlighted { syntax_errors = false } -> ()
       | _ -> failwith "provider probe did not highlight valid source");
      let ranges = Snapshot.ranges result.snapshot in
      (match !expected with
       | None -> expected := Some ranges
       | Some before ->
         if before <> ranges then failwith "nondeterministic provider output")
    done;
    let elapsed = Unix.gettimeofday () -. started in
    Printf.printf "%s batch %d: full parse/query/normalize %.3f ms/call, RSS after GC %d KiB\n%!"
      name batch (elapsed *. 1000. /. 50.) (sample ())
  done;
  Provider.close provider;
  Printf.printf "%s: RSS after close/GC %d KiB\n%!" name (sample ())
;;

let () =
  observe ".ml" Language.Ocaml "let f x = \"é\" (* outer (* inner *) *)\n";
  observe ".mli" Language.Ocaml_interface "val f : int -> string\n(* outer (* inner *) *)\n"
;;
