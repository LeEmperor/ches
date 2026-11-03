open! Core
module H = Ches_screen.Jump_history

let loc offset : H.location = { path = "document"; offset }
let back t current = H.peek_back t ~current:(loc current) |> Option.value_exn
let forward t current = H.peek_forward t ~current:(loc current) |> Option.value_exn
let jump t a b = H.record t ~origin:(loc a) ~destination:(loc b)

let%test_unit "back and forward preserve actual cursors and truncate branches" =
  let t = jump (jump H.empty 0 10) 12 20 in
  let location, t = back t 23 in
  assert (H.equal_location location (loc 12));
  let location, t = back t 13 in
  assert (H.equal_location location (loc 0));
  let location, t = forward t 1 in
  assert (H.equal_location location (loc 13));
  let location, _ = forward t 14 in
  assert (H.equal_location location (loc 23));
  let t = jump t 14 30 in
  assert (Option.is_none (H.peek_forward t ~current:(loc 30)));
  let location, _ = back t 30 in
  assert (H.equal_location location (loc 14))
;;

let%test_unit "no-op jumps preserve forward history and adjacent duplicates collapse" =
  let t = jump (jump H.empty 0 10) 0 10 in
  let location, t = back t 10 in
  assert (H.equal_location location (loc 0));
  assert (Option.is_none (H.peek_back t ~current:(loc 0)));
  let location, _ = forward (jump t 0 0) 0 in
  assert (H.equal_location location (loc 10));
  assert (Option.is_none (H.peek_back (jump H.empty 3 3) ~current:(loc 3)));
  let t = jump (jump H.empty 0 10) 10 20 in
  let location, _ = back t 10 in
  assert (H.equal_location location (loc 0))
;;

let%test_unit "traversal is transactional and paths participate in identity" =
  let other : H.location = { path = "other"; offset = 0 } in
  let t = H.record H.empty ~origin:(loc 0) ~destination:other in
  let first, _tentative = H.peek_back t ~current:other |> Option.value_exn in
  let again, _ = H.peek_back t ~current:other |> Option.value_exn in
  assert (H.equal_location first again);
  assert (H.equal_location first (loc 0))
;;

let%test_unit "128 prior locations are retained after many jumps" =
  let t = List.fold (List.init 300 ~f:Fn.id) ~init:H.empty
      ~f:(fun t i -> jump t i (i + 1)) in
  let rec collect t current acc =
    match H.peek_back t ~current with
    | None -> List.rev acc
    | Some (location, t) -> collect t location (location.offset :: acc)
  in
  let offsets = collect t (loc 300) [] in
  [%test_eq: int] (List.length offsets) 128;
  [%test_eq: int] (List.hd_exn offsets) 299;
  [%test_eq: int] (List.last_exn offsets) 172
;;
