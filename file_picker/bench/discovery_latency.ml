(* Warm filesystem, ten headless samples; not terminal or p99 latency. *)
open! Core
open! Async
module Provider = Ches_file_discovery.Provider
module Discovery = Ches_file_picker.Model.Discovery

let now () = Or_error.ok_exn Core_unix.Clock.gettime Core_unix.Clock.Monotonic
let elapsed start = Int63.to_float (Int63.( - ) (now ()) start) /. 1e6

let sample provider ~root =
  let start = now () in
  let run = Provider.start provider ~root |> Or_error.ok_exn in
  let rec poll () =
    ignore (Provider.poll provider ~max_batches:1 : Discovery.t option);
    let snapshot = Option.value_exn (Provider.snapshot provider) in
    match snapshot.status with
    | Loading | Partial ->
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in
      poll ()
    | Complete { truncated = false } ->
      let%map () = Provider.finished run in
      elapsed start, List.length snapshot.candidates
    | Complete { truncated = true } -> failwith "Discovery probe truncated; narrow dataset"
    | Failed message -> failwith message
    | Cancelled -> failwith "Discovery probe cancelled"
  in
  Monitor.protect poll ~finally:(fun () ->
    Provider.cancel provider;
    Provider.finished run)
;;

let () =
  let root =
    match Stdlib.Sys.argv with
    | [| _; root |] -> root
    | _ -> failwith "Usage: discovery_latency.exe ABSOLUTE_ROOT"
  in
  Thread_safe.block_on_async_exn (fun () ->
    let provider = Provider.create () in
    let%bind _, expected = sample provider ~root in
    let%map samples = Deferred.List.init 10 ~how:`Sequential ~f:(fun _ ->
      let%map ms, count = sample provider ~root in
      assert (count = expected);
      ms)
    in
    let sorted = List.sort samples ~compare:Float.compare in
    Stdlib.Printf.printf "count=%d samples_ms=%s median_ms=%.3f max_ms=%.3f\n%!"
      expected (String.concat ~sep:"," (List.map samples ~f:(sprintf "%.3f")))
      (List.nth_exn sorted 5) (List.last_exn sorted))
;;
