open! Core
open Ches_palette

let strings max_length =
  let rec exact n =
    if n = 0
    then [ "" ]
    else List.concat_map (exact (n - 1)) ~f:(fun s -> [ s ^ "a"; s ^ "b" ])
  in
  List.concat_map (List.range 0 (max_length + 1)) ~f:exact
;;

let reference_subsequence query text =
  let rec loop i j =
    if i = String.length query
    then true
    else if j = String.length text
    then false
    else if Char.equal query.[i] text.[j]
    then loop (i + 1) (j + 1)
    else loop i (j + 1)
  in
  loop 0 0
;;

let%expect_test "feasibility prefilter agrees with an independent exhaustive reference" =
  List.iter (strings 5) ~f:(fun text ->
    let fields = [ { Fuzzy.Field.tag = (); text; weight = 100 } ] in
    List.iter (strings 4) ~f:(fun query ->
      let loose = Fuzzy.rank ~policy:Loose_subsequence ~query [ (), fields ] in
      assert (Bool.equal (not (List.is_empty loose)) (reference_subsequence query text));
      List.iter loose ~f:(fun result ->
        if not (String.is_empty query)
        then (
          let offsets = snd (List.hd_exn result.positions) in
          assert (List.equal Int.equal offsets (List.dedup_and_sort offsets ~compare:Int.compare));
          let recovered = String.of_char_list (List.map offsets ~f:(fun i -> text.[i])) in
          assert (String.equal recovered query)));
      List.iter (Fuzzy.rank ~query [ (), fields ]) ~f:(fun result ->
        assert (reference_subsequence query text);
        assert (result.score = (List.hd_exn loose).score))));
  print_endline "1953 combinations passed";
  [%expect {| 1953 combinations passed |}]
;;
