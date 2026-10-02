open! Core

module B = Text_buffer

type t =
  { start : int
  ; stop : int
  ; kind : Register.Kind.t
  }
[@@deriving sexp_of, equal]

let linewise text ~cursor ~destination =
  let first = Int.min (B.line_of_offset text cursor) (B.line_of_offset text destination) in
  let last = Int.max (B.line_of_offset text cursor) (B.line_of_offset text destination) in
  let start = B.line_start text first in
  let stop =
    if last + 1 < B.line_count text then B.line_start text (last + 1) else B.length text
  in
  { start; stop; kind = Linewise }
;;

let characterwise text motion ~cursor ~destination ~inclusive =
  (* Vim's [dw] stops before the following line when it crosses a newline from a
     nonempty current line.  The ordinary exclusive range remains useful on an
     empty line and for all other motions. *)
  let destination =
    match motion with
    | Motion.Word_forward _
      when destination > B.line_end text (B.line_of_offset text cursor)
           && cursor < B.line_end text (B.line_of_offset text cursor) ->
      B.line_end text (B.line_of_offset text cursor)
    | _ -> destination
  in
  let destination =
    match motion with
    | Motion.Line_end when destination > B.line_start text (B.line_of_offset text destination) ->
      Option.value_exn (B.prev_boundary text destination)
    | _ -> destination
  in
  let start, stop = Int.min cursor destination, Int.max cursor destination in
  let start, stop =
    if inclusive
    then (
      if destination >= cursor
      then start, Option.value (B.next_boundary text destination) ~default:destination
      else start, Option.value (B.next_boundary text cursor) ~default:cursor)
    else start, stop
  in
  { start; stop; kind = Characterwise }
;;

let resolve text motion ~cursor ~preferred_column ~count =
  Motion.destination text motion ~cursor ~preferred_column ~count
  |> Result.map ~f:(fun destination ->
    match Motion.kind motion with
    | Linewise -> linewise text ~cursor ~destination
    | Characterwise { inclusive } -> characterwise text motion ~cursor ~destination ~inclusive)
;;

let resolve_destination text motion ~cursor ~destination =
  match Motion.kind (Motion.Find motion) with
  | Linewise -> assert false
  | Characterwise { inclusive } -> characterwise text (Motion.Find motion) ~cursor ~destination ~inclusive
;;

type word_class =
  | Identifier
  | Punctuation
[@@deriving equal]

let word_class_at text offset =
  if offset >= B.length text
  then None
  else (
    let code = Uchar.to_scalar (B.uchar_at text offset) in
    if code = 0x20 || code = 0x09 || code = 0x0A
    then None
    else if code >= 0x80 || Char.is_alphanum (Char.of_int_exn code) || code = Char.to_int '_'
    then Some Identifier
    else Some Punctuation)
;;

let inner_word text ~cursor =
  let rec next_word offset =
    if offset >= B.length text
    then None
    else if Option.is_some (word_class_at text offset)
    then Some offset
    else next_word (Option.value_exn (B.next_boundary text offset))
  in
  match next_word cursor with
  | None -> None
  | Some inside ->
    let class_ = Option.value_exn (word_class_at text inside) in
    let rec start offset =
      match B.prev_boundary text offset with
      | Some previous when Option.value_map (word_class_at text previous) ~default:false ~f:(equal_word_class class_) ->
        start previous
      | None | Some _ -> offset
    in
    let rec stop offset =
      match word_class_at text offset with
      | Some class' when equal_word_class class_ class' ->
        stop (Option.value_exn (B.next_boundary text offset))
      | None | Some _ -> offset
    in
    Some { start = start inside; stop = stop inside; kind = Register.Kind.Characterwise }
;;
