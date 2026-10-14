open! Core
open Ches_core
module B = Text_buffer

let get = function Ok x -> x | Error e -> failwith (B.Invalid_text.to_string_hum e)

let () =
  printf "Text edits only; CPU time, GC allocated bytes; 3 warmups + 24 samples/case.\n";
  List.iter [65536; 209920; 1048576] ~f:(fun size ->
    let source = String.init size ~f:(fun i -> if i % 80 = 79 then '\n' else 'a') in
    let t = get (B.of_string source) in
    let pos = size / 2 in
    List.iter ["insert", 0, "x"; "delete", 1, ""; "replace", 1, "z"; "newline", 0, "\n"]
      ~f:(fun (name, len, s) ->
        let edit () = get (B.replace t ~pos ~len s) in
        for _ = 1 to 3 do ignore (edit () : B.t) done;
        let samples = Array.init 24 ~f:(fun _ ->
          let bytes = Stdlib.Gc.allocated_bytes () in
          let time = Stdlib.Sys.time () in
          let result = edit () in
          let elapsed = (Stdlib.Sys.time () -. time) *. 1000. in
          let bytes = Stdlib.Gc.allocated_bytes () -. bytes in
          assert (B.length result = size - len + String.length s);
          elapsed, bytes) in
        let times = Array.map samples ~f:fst in
        Array.sort times ~compare:Float.compare;
        let allocation = Array.fold samples ~init:0. ~f:(fun sum (_, b) -> sum +. b) /. 24. in
        let result, work = B.For_testing.measure edit in
        assert (String.equal (B.to_string result)
          (String.prefix source pos ^ s ^ String.drop_prefix source (pos + len)));
        printf "%d %s median_cpu_ms=%.4f max_cpu_ms=%.4f allocated_bytes/op=%.0f destinations=%d destination_bytes=%d old_scan=%d inserted_scan=%d\n%!"
          size name ((times.(11) +. times.(12)) /. 2.) times.(23) allocation
          work.destinations work.destination_bytes work.full_scan_bytes work.inserted_scan_bytes))
