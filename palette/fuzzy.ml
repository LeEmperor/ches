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

(* The original ranker above remains the independent alignment/ranking oracle.
   This path keeps compact immutable fields and query-local rolling DP storage. *)
module Fast = struct
  module Query = struct
    type t = int array array
    let compile query = Array.of_list (tokens query)
    let is_empty t = Array.is_empty t
    let equal a b = Array.equal (Array.equal Int.equal) a b
    let retained_bytes t = 32 + 8 * Array.length t
      + Array.fold t ~init:0 ~f:(fun bytes token -> bytes + 16 + 8 * Array.length token)
    ;;
    (* Under loose token-AND semantics, extending each old folded token in the
       corresponding position and adding tokens can only remove matches. *)
    let is_extension ~previous ~next =
      Array.length previous > 0 && Array.length previous <= Array.length next
      && Array.for_alli previous ~f:(fun i token ->
        Array.length token <= Array.length next.(i)
        && Array.for_alli token ~f:(fun j scalar -> scalar = next.(i).(j)))
    ;;
  end

  module Text = struct
    type chars = Ascii of string | Unicode of int array * int array
    type t = { chars : chars; bonuses : string; length : int }
    let create text =
      let ascii = String.for_all text ~f:(fun c -> Char.to_int c < 128) in
      if ascii then (
        let length = String.length text in
        let chars = String.map text ~f:(fun c -> Char.of_int_exn (fold (Char.to_int c))) in
        let bonuses = String.init length ~f:(fun j ->
          let previous = if j = 0 then Separator else classify (Char.to_int text.[j - 1]) in
          Char.of_int_exn (bonus ~previous ~current:(classify (Char.to_int text.[j])))) in
        { chars = Ascii chars; bonuses; length })
      else (
        let decoded = decode text in
        { chars = Unicode (Array.map decoded ~f:(fun (c, _) -> fold c), Array.map decoded ~f:snd)
        ; bonuses = String.init (Array.length decoded) ~f:(fun j ->
            let previous = if j = 0 then Separator else classify (fst decoded.(j - 1)) in
            Char.of_int_exn (bonus ~previous ~current:(classify (fst decoded.(j)))))
        ; length = Array.length decoded })
    ;;
    let char t j = match t.chars with
      | Ascii s -> Char.to_int s.[j]
      | Unicode (chars, _) -> chars.(j)
    let offset t j = match t.chars with Ascii _ -> j | Unicode (_, offsets) -> offsets.(j)
    let retained_bytes t = String.length t.bonuses + (match t.chars with
      | Ascii s -> String.length s
      | Unicode (chars, offsets) -> 8 * (Array.length chars + Array.length offsets))
  end

  module Field = struct
    type t = { text : Text.t; start : int; length : int; weight : int }
    let create text ~byte_start ~weight =
      let start = ref 0 in
      while !start < text.Text.length && Text.offset text !start < byte_start do incr start done;
      { text; start = !start; length = text.length - !start; weight }
    ;;
    let char t j = Text.char t.text (t.start + j)
    let bonus t j = if j = 0 then bonus ~previous:Separator ~current:(classify (char t j))
      else Char.to_int t.text.bonuses.[t.start + j]
    let offset t j = Text.offset t.text (t.start + j)
  end

  module Scratch = struct
    type t =
      { mutable previous : int array; mutable current : int array
      ; mutable parents : int array; mutable last_parent : int array
      ; mutable scoring_calls : int; mutable alignment_calls : int
      ; mutable endpoint : int
      ; trace_limit : int }
    let create ?(trace_limit = 262_144) () =
      if trace_limit < 0 || trace_limit > 262_144 then invalid_arg "Fuzzy traceback budget";
      { previous = [||]; current = [||]; parents = [||]; last_parent = [||]
      ; scoring_calls = 0; alignment_calls = 0; endpoint = -1; trace_limit }
    let ensure t n =
      if Array.length t.previous < n then (
        t.previous <- Array.create ~len:n impossible;
        t.current <- Array.create ~len:n impossible;
        t.last_parent <- Array.create ~len:n (-1))
    let capacity t = Array.length t.previous + Array.length t.current + Array.length t.last_parent
    let trace_capacity t = Array.length t.parents
    let scoring_calls t = t.scoring_calls
    let alignment_calls t = t.alignment_calls
  end

  let no_match = impossible
  let subsequence token (field : Field.t) =
    let next = ref 0 and j = ref 0 in
    while !next < Array.length token && !j < field.length do
      if token.(!next) = Field.char field !j then incr next;
      incr j
    done;
    !next = Array.length token
  ;;
  let qualifies policy m score = match policy with
    | Policy.Loose_subsequence -> true
    | Command -> score * 100 >= ideal_score m * 50
  ;;

  (* Return the earliest best endpoint; exact ties/parent choices mirror the oracle.
     Optional parent recording does not retain the score matrix. *)
  let dp scratch token m (field : Field.t) ~trace =
    let n = field.length in
    Scratch.ensure scratch n;
    let previous = ref scratch.Scratch.previous and current = ref scratch.current in
    for j = 0 to n - 1 do
      (!previous).(j) <- if token.(0) = Field.char field j
        then score_match + first_char_multiplier * Field.bonus field j else impossible
    done;
    for i = 1 to m - 1 do
      let gap_score = ref impossible and gap_from = ref (-1) in
      for j = 0 to n - 1 do
        (!current).(j) <- impossible;
        scratch.last_parent.(j) <- -1;
        if j >= i then (
          if j >= 2 then (
            if !gap_score <> impossible then gap_score := !gap_score - gap_extension;
            let k = j - 2 in
            if (!previous).(k) <> impossible && (!previous).(k) - gap_start > !gap_score then (
              gap_score := (!previous).(k) - gap_start; gap_from := k));
          if token.(i) = Field.char field j then (
            let consecutive = if (!previous).(j - 1) = impossible then impossible
              else (!previous).(j - 1) + bonus_consecutive in
            let parent = if consecutive >= !gap_score then j - 1 else !gap_from in
            let best = if consecutive >= !gap_score then consecutive else !gap_score in
            if best <> impossible then (
              (!current).(j) <- best + score_match + Field.bonus field j;
              scratch.last_parent.(j) <- parent;
              if trace then scratch.parents.(i * n + j) <- parent)))
      done;
      let old = !previous in previous := !current; current := old
    done;
    let best = ref impossible and endpoint = ref (-1) in
    for j = 0 to n - 1 do
      if (!previous).(j) > !best then (best := (!previous).(j); endpoint := j)
    done;
    scratch.endpoint <- !endpoint;
    !best
  ;;

  let token_score ~policy scratch token (field : Field.t) =
    let m = Array.length token and n = field.length in
    if m = 0 || m > n || not (subsequence token field) then impossible
    else (
      let raw =
        if m = 1 then (
          let best = ref impossible in
          for j = 0 to n - 1 do
            if token.(0) = Field.char field j then
              best := Int.max !best (score_match + first_char_multiplier * Field.bonus field j)
          done; !best)
        else if m = n then (
          let score = ref (score_match * m + first_char_multiplier * Field.bonus field 0
            + bonus_consecutive * (m - 1)) in
          for j = 1 to n - 1 do score := !score + Field.bonus field j done;
          !score)
        else dp scratch token m field ~trace:false in
      let score = raw + if m = n then bonus_exact else 0 in
      if qualifies policy m score then score else impossible)
  ;;

  let score ?(policy = Policy.Command) (scratch : Scratch.t) (query : Query.t) fields =
    scratch.Scratch.scoring_calls <- scratch.scoring_calls + 1;
    let total = ref 0 and valid = ref true and i = ref 0 in
    while !valid && !i < Array.length query do
      let best = ref impossible in
      for f = 0 to Array.length fields - 1 do
        let field = fields.(f) in
        let raw = token_score ~policy scratch query.(!i) field in
        if raw <> impossible then best := Int.max !best (raw * field.Field.weight / 100)
      done;
      if !best = impossible then valid := false else total := !total + !best;
      incr i
    done;
    if !valid then !total else impossible
  ;;

  let align_token scratch token (field : Field.t) =
    let m = Array.length token and n = field.length in
    if m = n then List.init n ~f:(Field.offset field)
    else if m = 1 then (
      let best = ref impossible and endpoint = ref (-1) in
      for j = 0 to n - 1 do
        if token.(0) = Field.char field j then (
          let score = score_match + first_char_multiplier * Field.bonus field j in
          if score > !best then (best := score; endpoint := j))
      done;
      [ Field.offset field !endpoint ])
    else (
      let trace = m <= scratch.Scratch.trace_limit / n in
      if trace && Array.length scratch.Scratch.parents < m * n then
        scratch.parents <- Array.create ~len:(m * n) (-1);
      ignore (dp scratch token m field ~trace : int);
      let endpoint = scratch.endpoint in
      let rec collect i j acc =
        let acc = Field.offset field j :: acc in
        if i = 0 then acc else (
          (* Oversized alignments recompute prefix rows instead of allocating an
             unbounded traceback matrix. Same parent policy; higher worst-case CPU. *)
          if not trace then ignore (dp scratch token (i + 1) field ~trace:false : int);
          let parent = if trace then scratch.parents.(i * n + j) else scratch.last_parent.(j) in
          collect (i - 1) parent acc)
      in collect (m - 1) endpoint [])
  ;;

  let positions ?(policy = Policy.Command) (scratch : Scratch.t) (query : Query.t) fields =
    scratch.Scratch.alignment_calls <- scratch.alignment_calls + 1;
    let offsets = ref [] in
    Array.iter query ~f:(fun token ->
      let best = ref impossible and selected = ref (-1) in
      Array.iteri fields ~f:(fun i field ->
        let raw = token_score ~policy scratch token field in
        if raw <> impossible then (
          let score = raw * field.Field.weight / 100 in
          if score > !best then (best := score; selected := i)));
      if !selected < 0 then invalid_arg "Alignment requested for a nonmatching candidate";
      offsets := List.rev_append (align_token scratch token fields.(!selected)) !offsets);
    List.dedup_and_sort !offsets ~compare:Int.compare
  ;;
end
