open! Core
open Ches_highlight

let key ?(document = Snapshot.Document_id.create ()) ?(revision = 0)
    ?(language = Language.Ocaml) ?(configuration = "synthetic-v1") () =
  Snapshot.Key.create ~document ~revision ~language ~configuration
;;
let range start stop category = { Snapshot.Range.start; stop; category }
let snapshot source ranges = Snapshot.create ~key:(key ()) ~source ranges

let%test_unit "nested and crossing overlaps, ties, duplicates and adjacent merging" =
  let input =
    [ range 0 12 String; range 2 10 Comment; range 4 6 Escape
    ; range 8 12 Keyword; range 8 12 Function; range 12 14 Keyword
    ; range 4 6 Escape; range 0 14 Plain
    ]
  in
  let expected =
    [ range 0 2 String; range 2 4 Comment; range 4 6 Escape
    ; range 6 8 Comment; range 8 14 Keyword
    ]
  in
  List.iter [ input; List.rev input; List.drop input 3 @ List.take input 3 ] ~f:(fun ranges ->
    [%test_result: Snapshot.Range.t list]
      (Snapshot.ranges (snapshot "abcdefghijklmn" ranges)) ~expect:expected);
  (* Equal category and length crossing: earlier start is the deterministic tie. *)
  [%test_result: Snapshot.Range.t list]
    (Snapshot.ranges (snapshot "abcdef" [ range 2 6 Type; range 0 4 Type ]))
    ~expect:[ range 0 6 Type ]
;;

let%test_unit "UTF-8 boundaries, multiline ranges and invalid/empty captures" =
  let source = "é\n界x" in
  let s = snapshot source
      [ range 0 6 Comment; range 3 6 Type; range 6 7 Number
      ; range 1 2 Escape; range 3 5 Keyword; range (-1) 2 String
      ; range 6 8 Keyword; range 4 4 Escape; range 5 3 Escape
      ; range Int.min_value Int.max_value Keyword
      ]
  in
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges s)
    ~expect:[ range 0 3 Comment; range 3 6 Type; range 6 7 Number ];
  [%test_result: Category.t list]
    (List.map [ -1; 0; 2; 3; 6; 7; Int.max_value ] ~f:(Snapshot.category_at s))
    ~expect:[ Plain; Comment; Comment; Type; Number; Plain; Plain ];
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges (snapshot "" [ range 0 0 Keyword ])) ~expect:[];
  assert (Exn.does_raise (fun () -> snapshot "\255" []))
;;

let%test_unit "capture mapping ignores unknown and internal categories" =
  List.iter
    [ "function.call", Category.Function; "type.builtin", Type
    ; "variable.parameter", Variable; "punctuation.bracket", Punctuation
    ; "string.special", String; "escape", Escape; "tag", Property
    ]
    ~f:(fun (capture, category) ->
      [%test_result: Category.t option] (Category.of_capture capture) ~expect:(Some category));
  List.iter [ "unknown"; "_internal"; "_function.call"; "" ] ~f:(fun capture ->
    [%test_result: Category.t option] (Category.of_capture capture) ~expect:None);
  let source = "abcdef" in
  let ranges = List.filter_map [ "unknown"; "keyword"; "_internal" ] ~f:(fun name ->
    Option.map (Category.of_capture name) ~f:(range 0 6))
  in
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges (snapshot source ranges))
    ~expect:[ range 0 6 Keyword ]
;;

let%test_unit "indexed intersections and cursor lookup, including backward and duplicate offsets" =
  let s = snapshot (String.make 100_000 'x')
      (List.init 20_000 ~f:(fun i -> range (i * 5) (i * 5 + 3) Keyword))
  in
  [%test_result: Snapshot.Range.t list] (Snapshot.intersecting s ~start:90_001 ~stop:90_007)
    ~expect:[ range 90_000 90_003 Keyword; range 90_005 90_008 Keyword ];
  List.iter [ 0, 0; 10, 5; 100_000, 100_100 ] ~f:(fun (start, stop) ->
    [%test_result: Snapshot.Range.t list] (Snapshot.intersecting s ~start ~stop) ~expect:[]);
  let lookup = Snapshot.lookup_from s 90_001 in
  List.iter [ 90_001; 90_001; 90_003; 90_004; 90_007; 99_999; 0; -1; 5 ] ~f:(fun offset ->
    [%test_result: Category.t] (lookup offset) ~expect:(Snapshot.category_at s offset))
;;

let%test_unit "snapshot freshness includes document, revision, language and configuration" =
  let document = Snapshot.Document_id.create () in
  let current = key ~document () in
  let s = Snapshot.create ~key:current ~source:"abc" [ range 0 3 Keyword ] in
  assert (Snapshot.matches s (key ~document ()));
  List.iter
    [ key (); key ~document ~revision:1 (); key ~document ~language:Plain ()
    ; key ~document ~configuration:"synthetic-v2" ()
    ] ~f:(fun k -> assert (not (Snapshot.matches s k)))
;;

let%test_unit "sweep agrees with independent per-byte overlap oracle" =
  let random = Random.State.make [| 20261004 |] in
  for _ = 1 to 100 do
    let input = List.init 80 ~f:(fun _ ->
      let start = Random.State.int random 40 in
      let stop = start + 1 + Random.State.int random (40 - start) in
      let category = List.nth_exn Category.all (1 + Random.State.int random 14) in
      range start stop category)
    in
    let s = snapshot (String.make 40 'x') input in
    for offset = 0 to 40 do
      let covered = List.filter input ~f:(fun r -> r.start <= offset && offset < r.stop) in
      let shortest = List.fold covered ~init:Int.max_value ~f:(fun n r -> Int.min n (r.stop - r.start)) in
      let expected =
        List.filter covered ~f:(fun r -> r.stop - r.start = shortest)
        |> List.min_elt ~compare:(fun a b -> Int.compare (Category.priority a.category) (Category.priority b.category))
        |> Option.value_map ~default:Category.Plain ~f:(fun r -> r.category)
      in
      [%test_result: Category.t] (Snapshot.category_at s offset) ~expect:expected
    done;
    [%test_result: Snapshot.Range.t list]
      (Snapshot.ranges (snapshot (String.make 40 'x') (List.rev input)))
      ~expect:(Snapshot.ranges s)
  done
;;
