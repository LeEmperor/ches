open! Core
open Ches_core
module B = Text_buffer

let text s = B.of_string s |> Result.ok |> Option.value_exn
let replace t ~pos ~len s = B.replace t ~pos ~len s |> Result.ok |> Option.value_exn

(* Independent byte/string oracle, deliberately using whole-string scans and copies.
   Normalize after each half, as the original delete+insert implementation did. *)
let start s at =
  let found = ref 0 in
  for i = 0 to at - 1 do if Char.equal s.[i] '\n' then found := i + 1 done;
  !found
;;
let normalize s ids =
  List.map ids ~f:(fun (at, token) -> start s at, token)
  |> List.sort ~compare:[%compare: int * string]
;;
let reference s ids ~pos ~len inserted ~right ~linewise ~preserve ~new_ids =
  let stop = pos + len in
  let deleted = String.prefix s pos ^ String.drop_prefix s stop in
  let ids =
    if len = 0 then (if linewise then List.filter ids ~f:(fun (at, _) -> at <> pos) else ids)
    else List.filter_map ids ~f:(fun (at, token) ->
      let ending = String.index_from s at '\n' |> Option.value ~default:(String.length s) in
      if not preserve && at >= pos && at < stop && (linewise || ending < stop) then None
      else Some ((if at >= stop then at - len else if at >= pos then pos else at), token))
  in
  let ids = normalize deleted ids in
  let result = String.prefix deleted pos ^ inserted ^ String.drop_prefix deleted pos in
  let ids = if String.is_empty inserted then ids else
      List.map ids ~f:(fun (at, token) ->
        (if at > pos || (at = pos && right && String.contains inserted '\n')
         then at + String.length inserted else at), token)
      @ List.map new_ids ~f:(fun (at, token) -> pos + at, token) in
  result, normalize result ids
;;

let check t s ids =
  [%test_result: string] (B.to_string t) ~expect:s;
  [%test_result: (int * string) list] (B.identities t) ~expect:ids;
  [%test_result: string option] (B.identity_scope t) ~expect:(Some "directory");
  [%test_result: string list]
    (List.init (B.line_count t) ~f:(B.line_text t)) ~expect:(String.split s ~on:'\n');
  for at = 0 to String.length s do
    if B.is_boundary t at then (
      let line = String.count (String.prefix s at) ~f:(Char.equal '\n') in
      [%test_result: int] (B.line_of_offset t at) ~expect:line;
      [%test_result: int] (B.line_start t line) ~expect:(start s at))
  done
;;

let%test_unit "independent randomized edit sequences, UTF8, newline edges and hidden anchors" =
  let rng = Stdlib.Random.State.make [| 7; 11; 2026 |] in
  let random n = Stdlib.Random.State.int rng n in
  let chunks = [| ""; "x"; "é"; "日"; "🐹"; "\n"; "\n\n"; "é\n日\n"; "\t" |] in
  for sequence = 0 to 99 do
    let s = ref "a\né\n\n日\n" in
    let ids = ref [ 0, "a"; 2, "b"; 5, "empty"; 6, "c"; 10, "end" ] in
    let t = ref (B.with_identities (text !s) ~scope:"directory" !ids) in
    for step = 0 to 79 do
      let boundaries = List.filter (List.range 0 (String.length !s + 1)) ~f:(fun at ->
        at = String.length !s || Char.to_int (!s).[at] land 0xc0 <> 0x80) |> Array.of_list in
      let a = boundaries.(random (Array.length boundaries)) in
      let b = boundaries.(random (Array.length boundaries)) in
      let pos = Int.min a b and len = Int.abs (a - b) in
      let inserted = chunks.(random (Array.length chunks)) in
      let right = random 2 = 0 and linewise = random 4 = 0 and preserve = random 3 = 0 in
      let new_ids = if random 4 = 0 && not (String.is_empty inserted)
        then [0, sprintf "new-%d-%d" sequence step] else [] in
      let old = !t in
      let expected, anchors = reference !s !ids ~pos ~len inserted ~right ~linewise ~preserve ~new_ids in
      t := B.replace !t ~pos ~len inserted ~identities:new_ids
        ~anchor_affinity:(if right then `Right else `Left) ~linewise ~preserve_identities:preserve
        |> Result.ok |> Option.value_exn;
      check !t expected anchors;
      (* Earlier snapshots and their warmed layouts remain valid. *)
      [%test_result: string] (B.to_string old) ~expect:!s;
      s := expected; ids := anchors
    done
  done
;;

let%test_unit "ordinary edits: one destination, no old-text scan or substring allocation" =
  List.iter [ 65536; 209920; 1048576 ] ~f:(fun size ->
    let source = String.init size ~f:(fun i -> if i % 80 = 79 then '\n' else 'a') in
    let t = text source in
    let run f expected_size max_scan =
      let before = Stdlib.Gc.allocated_bytes () in
      let result, work = B.For_testing.measure f in
      let allocated = Stdlib.Gc.allocated_bytes () -. before in
      [%test_result: int] work.full_scan_bytes ~expect:0;
      [%test_result: int] work.destinations ~expect:1;
      [%test_result: int] work.destination_bytes ~expect:expected_size;
      assert (work.inserted_scan_bytes <= max_scan);
      (* One text + at most one line array + fixed small record/closure overhead.
         A temporary prefix/suffix pair or intermediate document exceeds this. *)
      let budget = expected_size + 8 * (B.line_count result + 1) + 8192 in
      assert (Float.(allocated < of_int budget));
      result
    in
    ignore (run (fun () -> B.insert t ~at:1 "x" |> Result.ok |> Option.value_exn) (size + 1) 2 : B.t);
    ignore (run (fun () -> B.delete t ~pos:1 ~len:1) (size - 1) 0 : B.t);
    let replaced = run (fun () -> replace t ~pos:1 ~len:1 "z") size 1 in
    (* Equal-length replacement must allocate no new line array. *)
    let before = Stdlib.Gc.allocated_bytes () in
    ignore (replace replaced ~pos:1 ~len:1 "a" : B.t);
    let budget = size + 8192 in
    assert (Float.(Stdlib.Gc.allocated_bytes () -. before < of_int budget));
    [%test_result: int] (B.retained_bytes replaced) ~expect:(B.retained_bytes t);
    let no_op, work = B.For_testing.measure (fun () -> replace t ~pos:1 ~len:0 "") in
    assert (phys_equal t no_op);
    [%test_result: int] work.destinations ~expect:0)
;;

let%test_unit "replacement validates input and boundaries and invalidates layouts" =
  let t = text "a日\nx" in
  List.iter ["\xff"; "\r\n"; "\000"; "\r"] ~f:(fun s ->
    assert (Result.is_error (B.replace t ~pos:1 ~len:3 s)));
  List.iter [2, 1; 1, 1; 0, -1; 0, 99] ~f:(fun (pos, len) ->
    assert (Exn.does_raise (fun () -> B.replace t ~pos ~len "x")));
  let width _ = 1 in
  let old = B.line_layout t ~width 0 in
  let edited = replace t ~pos:1 ~len:3 "abc" in
  assert (not (phys_equal old (B.line_layout edited ~width 0)));
  assert (phys_equal old (B.line_layout t ~width 0));
  [%test_result: string] (B.to_string t) ~expect:"a日\nx"
;;

let%test_unit "exhaustive newline boundaries, trailing/empty lines and affinities" =
  List.iter [""; "\n"; "\n\n"; "é\n日\n"; "a\n\nb"] ~f:(fun s ->
    let base = text s in
    let ids = List.init (B.line_count base) ~f:(fun line -> B.line_start base line, Int.to_string line) in
    let base = B.with_identities base ~scope:"directory" ids in
    let boundaries = List.filter (List.range 0 (String.length s + 1)) ~f:(B.is_boundary base) in
    List.iter boundaries ~f:(fun pos -> List.iter boundaries ~f:(fun stop ->
      if stop >= pos then List.iter [""; "\n"; "x"; "日\n\n"] ~f:(fun inserted ->
        List.iter [false; true] ~f:(fun right ->
          let new_ids = [0, "new"] in
          let expected, anchors = reference s ids ~pos ~len:(stop - pos) inserted
            ~right ~linewise:false ~preserve:false ~new_ids in
          let edited = B.replace base ~pos ~len:(stop - pos) inserted ~identities:new_ids
            ~anchor_affinity:(if right then `Right else `Left) |> Result.ok |> Option.value_exn in
          check edited expected anchors)))))
;;
