open! Core
open Ches_core
open Ches_completion.Model
module B = Text_buffer
module W = Buffer_words

let text s = B.of_string s |> Result.ok |> Option.value_exn
let replace t ~pos ~len s = B.replace t ~pos ~len s |> Result.ok |> Option.value_exn
let labels words t cursor limit =
  W.candidates words ~text:t ~cursor ~limit
  |> List.map ~f:(fun c -> c.Candidate.label)
;;
let check_labels words t cursor expected =
  [%test_eq: string list] (labels words t cursor 100) expected
;;
let fresh_agrees words t cursors =
  let fresh = W.create t in
  List.iter cursors ~f:(fun cursor ->
    List.iter [ 0; 1; 7; 100 ] ~f:(fun limit ->
      assert (List.equal Candidate.equal
        (W.candidates words ~text:t ~cursor ~limit)
        (W.candidates fresh ~text:t ~cursor ~limit))))
;;

let%test_unit "empty prefix is bounded and lexical, excludes only the sole current occurrence" =
  let t = text "Alpha beta alpha éclair" in
  let w = W.create t in
  (* Empty prefix before a word still excludes its sole current occurrence,
     before applying the limit. *)
  [%test_eq: string list] (labels w t 0 2) [ "alpha"; "beta" ];
  check_labels w t 0 [ "alpha"; "beta"; "éclair" ];
  assert (List.is_empty (labels w t 0 0));
  assert (List.is_empty (labels w t 0 (-1)));
  let duplicated = replace t ~pos:(B.length t) ~len:0 " Alpha" in
  let w = W.update w duplicated in
  [%test_eq: string list] (labels w duplicated 0 1) [ "Alpha" ];
  let w = W.update w t in
  [%test_eq: string list] (labels w t 0 1) [ "alpha" ];
  let empty = text "" in
  check_labels (W.create empty) empty 0 []
;;

let%test_unit "empty-slot model session takes only the first lexical candidates and inserts at the slot" =
  let vocabulary = List.init 150 ~f:(fun i -> sprintf "word%03d" i) in
  let t = text (". " ^ String.concat ~sep:" " (List.rev vocabulary)) in
  let token = { Token.resource = "empty-slot"; generation = 1; revision = 0; request = 1 } in
  let session, request = start ~token ~text:t ~cursor:1 ~words:(W.create t) ~limit:100
    |> Option.value_exn in
  [%test_eq: string list] (List.map (candidates session) ~f:(fun c -> c.Candidate.label))
    (List.take vocabulary 100);
  assert (request.fallback_start = 1 && request.fallback_stop = 1);
  let p = plan session Next |> Option.value_exn in
  let inserted = Text_edit.apply t (edits p) |> Or_error.ok_exn in
  [%test_eq: string] (B.to_string inserted)
    (".word000 " ^ String.concat ~sep:" " (List.rev vocabulary));
  assert (cursor p = 8)
;;

let%test_unit "tail beyond 64 KiB, lexical case sensitivity and bounded results" =
  let t = text ("al Al é 中 " ^ String.make 100000 ' ' ^
    "alpine alpha albatross Alpha éclair école 中文 中华") in
  let words, scanned = W.For_testing.measure (fun () -> W.create t) in
  assert (scanned = B.length t);
  check_labels words t 2 [ "albatross"; "alpha"; "alpine" ];
  check_labels words t 5 [ "Alpha" ];
  check_labels words t 8 [ "éclair"; "école" ];
  check_labels words t 12 [ "中华"; "中文" ];
  [%test_eq: string list] (labels words t 2 1) [ "albatross" ];
  assert (List.is_empty (labels words t 7 100));
  assert (List.is_empty (labels words (text (B.to_string t)) 2 100))
;;

let%test_unit "local large-buffer changes scan words only, preserve old indexes" =
  let head = "al é " in
  let t = text (head ^ String.concat (List.init 20000 ~f:(fun _ -> "filler ")) ^ "alpha éclair") in
  let words = W.create t in
  let at = B.length t - String.length "alpha éclair" in
  let edited = replace t ~pos:at ~len:5 "alpine" in
  let updated, scanned = W.For_testing.measure (fun () -> W.update words edited) in
  assert (scanned = 11);
  check_labels words t 2 [ "alpha" ];
  check_labels updated edited 2 [ "alpine" ];
  let removed = B.delete edited ~pos:at ~len:7 in
  let updated, scanned = W.For_testing.measure (fun () -> W.update updated removed) in
  assert (scanned < 32);
  check_labels updated removed 2 [];
  check_labels updated removed 5 [ "éclair" ];
  let shifted = replace removed ~pos:0 ~len:0 "  " in
  let updated, scanned = W.For_testing.measure (fun () -> W.update updated shifted) in
  assert (scanned < 16);
  check_labels updated shifted 7 [ "éclair" ];
  assert (phys_equal updated (W.update updated shifted));
  let metadata = B.with_identities shifted ~scope:"test" [ 0, "row" ] in
  let updated, scanned = W.For_testing.measure (fun () -> W.update updated metadata) in
  assert (scanned = 0);
  check_labels updated metadata 7 [ "éclair" ]
;;

let%test_unit "counts exclude the current occurrence, including mid-word queries" =
  let t = text "alpha alpha al" in
  let w = W.create t in
  check_labels w t 2 [ "alpha" ];
  let t = B.delete t ~pos:6 ~len:6 in
  let w = W.update w t in
  check_labels w t 2 [];
  check_labels w t 8 [ "alpha" ];
  let t = B.delete t ~pos:0 ~len:6 in
  let w = W.update w t in
  check_labels w t 2 []
;;

let%test_unit "Unicode merges, splits, delimiters, full deletion and empty creation" =
  let t = text (String.make 70000 ' ' ^ "éclair🐹école 中华 中文 é 中") in
  let w = W.create t in
  let merged = B.delete t ~pos:70007 ~len:4 in
  let w = W.update w merged in
  check_labels w merged (B.length merged - 4) [ "éclairécole" ];
  let split = replace merged ~pos:70007 ~len:0 "\n" in
  let w = W.update w split in
  check_labels w split (B.length split - 4) [ "éclair"; "école" ];
  fresh_agrees w split [ 70002; 70009; B.length split ];
  let empty = B.delete split ~pos:0 ~len:(B.length split) in
  let w = W.update w empty in
  fresh_agrees w empty [ 0 ];
  let t = replace empty ~pos:0 ~len:0 "αβ αé α" in
  let w = W.update w t in
  check_labels w t (B.length t) [ "αé"; "αβ" ]
;;

let%test_unit "skipped snapshots, reverse undo, redo, branching and history overflow" =
  let base = text ("al " ^ String.make 90000 ' ' ^ "alpha alpine") in
  let w = W.create base in
  let a = replace base ~pos:90003 ~len:5 "albatross" in
  let b = replace a ~pos:0 ~len:0 "é " in
  let c = replace b ~pos:(B.length b) ~len:0 " alphabet" in
  let w = W.update w c in
  fresh_agrees w c [ 5; B.length c - 6 ];
  let undone = W.update w base in
  fresh_agrees undone base [ 2 ];
  let redone = W.update undone c in
  fresh_agrees redone c [ 5 ];
  let branch = replace base ~pos:90003 ~len:5 "algebra" in
  fresh_agrees (W.update redone branch) branch [ 2 ];
  let long = List.fold (List.init 70 ~f:Fn.id) ~init:base ~f:(fun t _ ->
    replace t ~pos:90003 ~len:0 "a ") in
  fresh_agrees (W.update undone long) long [ 2; 90004 ];
  let independent = text ("al " ^ String.make 90000 ' ' ^ "altered") in
  let w = W.update w independent in
  check_labels w independent 2 [ "altered" ];
  let identical = text (B.to_string independent) in
  let w, scanned = W.For_testing.measure (fun () -> W.update w identical) in
  assert (scanned = 0);
  check_labels w identical 2 [ "altered" ]
;;

let boundaries t =
  let rec loop at acc =
    match B.next_boundary t at with
    | None -> List.rev (at :: acc)
    | Some next -> loop next (at :: acc)
  in
  loop 0 []
;;

let%test_unit "deterministic random Unicode replacements agree with full rebuilds" =
  let random = Random.State.make [| 941; 763 |] in
  let pieces = [| ""; "a"; "al"; "alpha"; " "; "\n"; "é"; "中"; "🐹"; "_"; "β2"; "́" |] in
  let current = ref (text "alpha al alphabet élan é 中华 中 foo fo foo") in
  let index = ref (W.create !current) in
  for i = 0 to 399 do
    let points = Array.of_list (boundaries !current) in
    let a = Random.State.int random (Array.length points) in
    let b = Int.min (Array.length points - 1) (a + Random.State.int random 8) in
    let inserted = pieces.(Random.State.int random (Array.length pieces)) in
    let next = replace !current ~pos:points.(a) ~len:(points.(b) - points.(a)) inserted in
    (* Some updates intentionally span several edits. *)
    if i % 3 = 0 then index := W.update !index next;
    current := next;
    if i % 3 = 0 then fresh_agrees !index !current (boundaries !current)
  done;
  let index = W.update !index !current in
  fresh_agrees index !current (boundaries !current)
;;

let%test_unit "long single word crossing old cap is never truncated on local edits" =
  let t = text ("a " ^ String.make 100000 'a' ^ " alpha") in
  let w = W.create t in
  let edited = replace t ~pos:65536 ~len:1 "é" in
  let w = W.update w edited in
  fresh_agrees w edited [ 1; 65538 ];
  let split = replace edited ~pos:65536 ~len:2 " " in
  fresh_agrees (W.update w split) split [ 1; 65537 ]
;;
