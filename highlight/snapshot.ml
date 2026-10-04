open! Core

module Document_id = struct
  type t = unit ref
  let create () = ref ()
end

module Key = struct
  type t =
    { document : Document_id.t
    ; revision : int
    ; language : Language.t
    ; configuration : string
    }

  let create ~document ~revision ~language ~configuration =
    { document; revision; language; configuration }
  ;;
  let equal a b =
    phys_equal a.document b.document
    && Int.equal a.revision b.revision
    && Language.equal a.language b.language
    && String.equal a.configuration b.configuration
  ;;
  let revision t = t.revision
  let same_document a b = phys_equal a.document b.document
  let language t = t.language
  let configuration t = t.configuration
end

module Range = struct
  type t = { start : int; stop : int; category : Category.t }
  [@@deriving sexp_of, equal, compare]
end

module Ranked = struct
  module T = struct
    type t = Range.t
    let sexp_of_t = Range.sexp_of_t
    let compare (a : t) (b : t) =
      let rec first = function
        | [] -> 0
        | 0 :: rest -> first rest
        | c :: _ -> c
      in
      first
        [ Int.compare (a.stop - a.start) (b.stop - b.start)
        ; Int.compare (Category.priority a.category) (Category.priority b.category)
        ; Int.compare a.start b.start
        ; Int.compare a.stop b.stop
        ; Category.compare a.category b.category
        ]
    ;;
  end
  include T
  include Comparator.Make (T)
end

type t = { key : Key.t; spans : Range.t array }
let key t = t.key
let matches t key = Key.equal t.key key
let ranges t = Array.to_list t.spans

let create ~key ~source ranges =
  if not (Stdlib.String.is_valid_utf_8 source)
  then invalid_arg "Snapshot.create: invalid UTF-8 source";
  let length = String.length source in
  let boundary at =
    at >= 0 && at <= length
    && (at = length || Char.to_int source.[at] land 0xc0 <> 0x80)
  in
  let valid (r : Range.t) =
    r.start < r.stop && boundary r.start && boundary r.stop
    && not (Category.equal r.category Plain)
  in
  let events =
    List.filter ranges ~f:valid
    |> List.dedup_and_sort ~compare:Ranked.compare
    |> List.concat_map ~f:(fun r -> [ r.start, true, r; r.stop, false, r ])
    |> List.sort ~compare:(fun (a, _, _) (b, _, _) -> Int.compare a b)
  in
  let emit acc start stop category =
    match acc with
    | (prev : Range.t) :: rest
      when prev.stop = start && Category.equal prev.category category ->
      { prev with stop } :: rest
    | _ -> { Range.start; stop; category } :: acc
  in
  let rec sweep events active previous acc =
    match events with
    | [] -> List.rev acc
    | (at, _, _) :: _ ->
      let acc =
        match Set.min_elt active with
        | Some (r : Range.t) when previous < at -> emit acc previous at r.category
        | _ -> acc
      in
      let here, rest = List.split_while events ~f:(fun (offset, _, _) -> offset = at) in
      let active = List.fold here ~init:active ~f:(fun set (_, add, r) ->
        if add then Set.add set r else Set.remove set r)
      in
      sweep rest active at acc
  in
  { key; spans = Array.of_list (sweep events (Set.empty (module Ranked)) 0 []) }
;;

let lower_bound t offset =
  let rec loop lo hi =
    if lo = hi then lo
    else
      let mid = lo + (hi - lo) / 2 in
      if t.spans.(mid).stop <= offset then loop (mid + 1) hi else loop lo mid
  in
  loop 0 (Array.length t.spans)
;;

let at_index t index offset =
  if index < Array.length t.spans && t.spans.(index).start <= offset
  then t.spans.(index).category else Category.Plain
;;
let category_at t offset = at_index t (lower_bound t offset) offset

let intersecting t ~start ~stop =
  let rec loop i acc =
    if i = Array.length t.spans || t.spans.(i).start >= stop
    then List.rev acc
    else loop (i + 1) (t.spans.(i) :: acc)
  in
  if start >= stop then [] else loop (lower_bound t start) []
;;

let lookup_from t first =
  let index = ref (lower_bound t first) in
  let previous = ref first in
  fun offset ->
    if offset < !previous then index := lower_bound t offset;
    previous := offset;
    while !index < Array.length t.spans && t.spans.(!index).stop <= offset do
      incr index
    done;
    at_index t !index offset
;;
