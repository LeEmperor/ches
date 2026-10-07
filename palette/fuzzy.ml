open! Core

module Field = struct
  type 'tag t =
    { tag : 'tag
    ; text : string
    ; weight : int
    }
  [@@deriving sexp_of]
end

module Match = struct
  type ('item, 'tag) t =
    { item : 'item
    ; score : int
    ; positions : ('tag Field.t * int list) list
    }
  [@@deriving sexp_of]
end

(* Scores, after fzf's. *)
let score_match = 16
let gap_start = 3
let gap_extension = 1
let bonus_boundary = 8
let bonus_camel = 7
let bonus_consecutive = 4
let first_char_multiplier = 2
let bonus_exact = 2 * score_match

(* Keep command quality filtering the default; file search opts into subsequences. *)
module Policy = struct
  type t = Command | Loose_subsequence [@@deriving sexp_of, equal]
end

(* The score of [length] contiguous code points starting at a word boundary. *)
let ideal_score length =
  (score_match * length)
  + (first_char_multiplier * bonus_boundary)
  + (bonus_consecutive * (length - 1))
;;

(* Scalar values and byte offsets of the code points of [s]. *)
let decode s =
  let rec loop pos acc =
    if pos >= String.length s
    then Array.of_list_rev acc
    else (
      let decoded = Stdlib.String.get_utf_8_uchar s pos in
      let scalar = Uchar.to_scalar (Stdlib.Uchar.utf_decode_uchar decoded) in
      loop (pos + Stdlib.Uchar.utf_decode_length decoded) ((scalar, pos) :: acc))
  in
  loop 0 []
;;

let fold scalar =
  if scalar >= Char.to_int 'A' && scalar <= Char.to_int 'Z' then scalar + 32 else scalar
;;

type char_class =
  | Lower
  | Upper
  | Digit
  | Separator (** Any other ASCII character. *)
  | Non_ascii

let classify scalar =
  if scalar >= 128
  then Non_ascii
  else (
    let c = Char.of_int_exn scalar in
    if Char.is_lowercase c
    then Lower
    else if Char.is_uppercase c
    then Upper
    else if Char.is_digit c
    then Digit
    else Separator)
;;

let bonus ~previous ~current =
  match previous, current with
  | _, Separator -> 0
  | Separator, _ -> bonus_boundary
  | Lower, Upper -> bonus_camel
  | (Lower | Upper | Non_ascii), Digit -> bonus_camel
  | _ -> 0
;;

type prepared =
  { chars : int array (** Folded scalar values. *)
  ; offsets : int array
  ; bonuses : int array
  }

let prepare text =
  let decoded = decode text in
  { chars = Array.map decoded ~f:(fun (scalar, _) -> fold scalar)
  ; offsets = Array.map decoded ~f:snd
  ; bonuses =
      Array.mapi decoded ~f:(fun j (scalar, _) ->
        let previous = if j = 0 then Separator else classify (fst decoded.(j - 1)) in
        bonus ~previous ~current:(classify scalar))
  }
;;

let impossible = Int.min_value

(* Avoid allocating/scoring a matrix for fields that cannot possibly match.
   Especially important for loose file queries over tens of thousands of paths. *)
let is_subsequence token chars =
  let next = ref 0 in
  let j = ref 0 in
  while !next < Array.length token && !j < Array.length chars do
    if token.(!next) = chars.(!j) then incr next;
    incr j
  done;
  !next = Array.length token
;;

(* The best-scoring alignment of [token] in [field], as its score and the byte
   offsets of the matched code points. [score.(i).(j)] is the best score of
   [token.(0..i)] with [token.(i)] matched at [field.chars.(j)], and [from.(i).(j)]
   the column of [token.(i - 1)] in that alignment. *)
let match_token ~policy token field =
  let m = Array.length token
  and n = Array.length field.chars in
  if m = 0 || m > n || not (is_subsequence token field.chars)
  then None
  else (
    let score = Array.make_matrix ~dimx:m ~dimy:n impossible in
    let from = Array.make_matrix ~dimx:m ~dimy:n (-1) in
    for j = 0 to n - 1 do
      if token.(0) = field.chars.(j)
      then score.(0).(j) <- score_match + (first_char_multiplier * field.bonuses.(j))
    done;
    for i = 1 to m - 1 do
      let previous = score.(i - 1) in
      (* The best predecessor at least two columns back, less its gap's cost. *)
      let gap_score = ref impossible in
      let gap_from = ref (-1) in
      for j = i to n - 1 do
        if j >= 2
        then (
          if !gap_score <> impossible then gap_score := !gap_score - gap_extension;
          let k = j - 2 in
          if previous.(k) <> impossible && previous.(k) - gap_start > !gap_score
          then (
            gap_score := previous.(k) - gap_start;
            gap_from := k));
        if token.(i) = field.chars.(j)
        then (
          let consecutive =
            if previous.(j - 1) = impossible
            then impossible
            else previous.(j - 1) + bonus_consecutive
          in
          let best, k =
            if consecutive >= !gap_score then consecutive, j - 1 else !gap_score, !gap_from
          in
          if best <> impossible
          then (
            score.(i).(j) <- best + score_match + field.bonuses.(j);
            from.(i).(j) <- k))
      done
    done;
    let last = score.(m - 1) in
    let best_j =
      Array.foldi last ~init:None ~f:(fun j best s ->
        match best with
        | _ when s = impossible -> best
        | Some b when last.(b) >= s -> best
        | _ -> Some j)
    in
    Option.bind best_j ~f:(fun j ->
      let rec positions i j acc =
        let acc = field.offsets.(j) :: acc in
        if i = 0 then acc else positions (i - 1) from.(i).(j) acc
      in
      let exact = if m = n then bonus_exact else 0 in
      let score = last.(j) + exact in
      Option.some_if
        (match policy with
         | Policy.Command -> score * 100 >= ideal_score m * 50
         | Loose_subsequence -> true)
        (score, positions (m - 1) j [])))
;;

let tokens query =
  String.split_on_chars query ~on:[ ' '; '\t'; '\n'; '\r'; '\011'; '\012' ]
  |> List.filter ~f:(Fn.non String.is_empty)
  |> List.map ~f:(fun token -> Array.map (decode token) ~f:(fun (scalar, _) -> fold scalar))
;;

(* The candidate's total score and, per token, the index of its best field and the
   offsets matched there, if every token matches. *)
let match_candidate ~policy tokens fields =
  List.fold_until
    tokens
    ~init:(0, [])
    ~finish:Option.some
    ~f:(fun (total, matched) token ->
      let best =
        Array.foldi fields ~init:None ~f:(fun index best ((field : _ Field.t), prepared) ->
          match match_token ~policy token prepared with
          | None -> best
          | Some (raw, offsets) ->
            let score = raw * field.weight / 100 in
            (match best with
             | Some (best_score, _, _) when best_score >= score -> best
             | _ -> Some (score, index, offsets)))
      in
      match best with
      | None -> Stop None
      | Some (score, index, offsets) -> Continue (total + score, (index, offsets) :: matched))
;;

module Prepared = struct
  type ('item, 'tag) t = 'item * ('tag Field.t * prepared) array

  let fields fields =
    Array.of_list_map fields ~f:(fun (field : _ Field.t) -> field, prepare field.text)
  ;;

  let create (item, raw_fields) = item, fields raw_fields
end

let rank_candidates ~policy ~query ~prepare_fields candidates =
  match tokens query with
  | [] ->
    List.map candidates ~f:(fun (item, _) -> { Match.item; score = 0; positions = [] })
  | tokens ->
    List.filter_map candidates ~f:(fun (item, fields) ->
      let fields = prepare_fields fields in
      Option.map (match_candidate ~policy tokens fields) ~f:(fun (score, matched) ->
        let positions =
          Array.to_list fields
          |> List.filter_mapi ~f:(fun index (field, _) ->
            match
              List.concat_map matched ~f:(fun (i, offsets) ->
                if i = index then offsets else [])
            with
            | [] -> None
            | offsets -> Some (field, List.dedup_and_sort offsets ~compare:Int.compare))
        in
        { Match.item; score; positions }))
    |> List.stable_sort ~compare:(fun (a : _ Match.t) b -> Int.compare b.score a.score)
;;

let rank_prepared ?(policy = Policy.Command) ~query candidates =
  rank_candidates ~policy ~query ~prepare_fields:Fn.id candidates
;;

let rank ?(policy = Policy.Command) ~query candidates =
  (* Prepare one candidate at a time, as before; only explicit prepared callers
     retain the decoded collection. Empty queries do not prepare any fields. *)
  rank_candidates ~policy ~query ~prepare_fields:Prepared.fields candidates
;;
