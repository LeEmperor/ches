open! Core
module F = Ches_palette.Fuzzy
module Fast = F.Fast

let%test_unit "loose folded-token prefix proof accepts only compatible extensions and preserves membership" =
  List.iter [ "mod", "model", true; "MOD", "model", true; "模", "模型", true
            ; "É", "é", false; "mod", "mo d", false; "a b", "ab", false
            ; "a b", "a bc x", true; "a b", "ab bc", true
            ; "dir model", "model dir", false; "model ", "model\t x", true
            ; "", "model", false; "mo", "m", false; "m", "nm", false ]
    ~f:(fun (old, next, expected) ->
      assert (Bool.equal expected (Fast.Query.is_extension ~previous:(Fast.Query.compile old) ~next:(Fast.Query.compile next)));
      if expected then List.iter [ "src/model"; "界/模型"; "Écoleé"; "ab bc x"; "MODEL_x" ] ~f:(fun text ->
        let candidates = [ (), [ { F.Field.tag = (); text; weight = 100 } ] ] in
        if not (List.is_empty (F.rank ~policy:Loose_subsequence ~query:next candidates)) then
          assert (not (List.is_empty (F.rank ~policy:Loose_subsequence ~query:old candidates)))))
;;

let check ~policy text query =
  let compiled = Fast.Query.compile query in
  let field = Fast.Field.create (Fast.Text.create text) ~byte_start:0 ~weight:100 in
  let scratch = Fast.Scratch.create () in
  let actual = Fast.score ~policy scratch compiled [| field |] in
  let expected = F.rank ~policy ~query [ (), [ { F.Field.tag = (); text; weight = 100 } ] ] in
  match expected with
  | [] -> assert (actual = Fast.no_match)
  | [ matched ] ->
    [%test_eq: int] actual matched.score;
    let positions = List.concat_map matched.positions ~f:snd |> List.dedup_and_sort ~compare:Int.compare in
    [%test_eq: int list] (Fast.positions ~policy scratch compiled [| field |]) positions;
    (* Force the bounded-memory recomputation path using small ordinary fixtures. *)
    [%test_eq: int list]
      (Fast.positions ~policy (Fast.Scratch.create ~trace_limit:0 ()) compiled [| field |]) positions
  | _ -> assert false
;;

let%test_unit "rolling scores and both traceback paths equal independent legacy DP on deterministic randomized Unicode inputs" =
  let random = Stdlib.Random.State.make [| 62026 |] in
  let alphabet = [| "a"; "B"; "c"; "9"; "_"; "/"; "-"; " "; "界"; "é"; "É"; "\xff"; "\xe0"; "\n"; "\t"; "\\" |] in
  let generate length = String.concat (List.init length ~f:(fun _ ->
    alphabet.(Stdlib.Random.State.int random (Array.length alphabet)))) in
  for _ = 1 to 160 do
    let text = generate (1 + Stdlib.Random.State.int random 28) in
    let queries = [ ""; " \t\n"; "a"; "B"; "É"; "�"; "a B"; text
                  ; generate (1 + Stdlib.Random.State.int random 7) ] in
    List.iter [ F.Policy.Command; Loose_subsequence ] ~f:(fun policy ->
      List.iter queries ~f:(check ~policy text))
  done;
  List.iter [ "a" ^ String.make 70 'x' ^ "b"; "aBaB99"; "界Éé"; "\xff\xe0a" ]
    ~f:(fun text -> List.iter [ "ab"; "AB"; "B9"; "É"; "é"; "�a" ]
      ~f:(fun query -> List.iter [ F.Policy.Command; Loose_subsequence ] ~f:(fun policy -> check ~policy text query)))
;;

let%test_unit "compact ASCII storage and score-only workspace do not allocate traceback or alignment state" =
  let text = "src/SomeModel99_abcdef.ml" in
  let prepared = Fast.Text.create text in
  assert (Fast.Text.retained_bytes prepared = 2 * String.length text);
  let fields = [| Fast.Field.create prepared ~byte_start:4 ~weight:150
               ; Fast.Field.create prepared ~byte_start:0 ~weight:100 |] in
  let scratch = Fast.Scratch.create () in
  let query = Fast.Query.compile "mo abc" in
  for _ = 1 to 100 do assert (Fast.score ~policy:Loose_subsequence scratch query fields <> Fast.no_match) done;
  assert (Fast.Scratch.scoring_calls scratch = 100);
  assert (Fast.Scratch.alignment_calls scratch = 0 && Fast.Scratch.trace_capacity scratch = 0);
  assert (Fast.Scratch.capacity scratch <= 3 * String.length text);
  let single = Fast.Scratch.create () in
  ignore (Fast.score ~policy:Loose_subsequence single (Fast.Query.compile "m") fields : int);
  assert (Fast.Scratch.capacity single = 0);
  let exact = Fast.Scratch.create () in
  ignore (Fast.score exact (Fast.Query.compile text)
    [| Fast.Field.create prepared ~byte_start:0 ~weight:100 |] : int);
  assert (Fast.Scratch.capacity exact = 0)
;;
