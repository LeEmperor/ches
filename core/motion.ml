open! Core
module B = Text_buffer

module Word = struct
  type t =
    | Small
    | Big
  [@@deriving sexp_of, equal, enumerate]
end

type t =
  | Left
  | Right
  | Up
  | Down
  | Word_forward of Word.t
  | Word_backward of Word.t
  | Word_end of Word.t
  | Line_start
  | First_nonblank
  | First_nonblank_down
  | Line_end
  | Last_nonblank
  | First_line
  | Last_line
  | Matching_delimiter
[@@deriving sexp_of, equal, enumerate]

module Failure = struct
  type t =
    | No_delimiter
    | Unmatched of char
  [@@deriving sexp_of, equal]

  let to_string = function
    | No_delimiter -> "No delimiter on this line"
    | Unmatched c -> sprintf "No match for %c" c
  ;;
end

module Kind = struct
  type t =
    | Characterwise of { inclusive : bool }
    | Linewise
  [@@deriving sexp_of, equal]
end

let kind : t -> Kind.t = function
  | Up | Down | First_nonblank_down | First_line | Last_line -> Linewise
  | Word_end _ | Line_end | Last_nonblank | Matching_delimiter ->
    Characterwise { inclusive = true }
  | Left | Right | Word_forward _ | Word_backward _ | Line_start | First_nonblank ->
    Characterwise { inclusive = false }
;;

let takes_count = function
  | Line_start | First_nonblank | Matching_delimiter -> false
  | Left
  | Right
  | Up
  | Down
  | Word_forward _
  | Word_backward _
  | Word_end _
  | First_nonblank_down
  | Line_end
  | Last_nonblank
  | First_line
  | Last_line -> true
;;

let keeps_preferred_column = function
  | Up | Down -> true
  | Left
  | Right
  | Word_forward _
  | Word_backward _
  | Word_end _
  | Line_start
  | First_nonblank
  | First_nonblank_down
  | Line_end
  | Last_nonblank
  | First_line
  | Last_line
  | Matching_delimiter -> false
;;

(* Word classes *)

type char_class =
  | Blank
  | Identifier
  | Punctuation
  | Non_blank
[@@deriving equal]

let char_class (word : Word.t) u =
  let code = Uchar.to_scalar u in
  if code = 0x20 || code = 0x09 || code = 0x0A
  then Blank
  else (
    match word with
    | Big -> Non_blank
    | Small ->
      if code >= 0x80
         || (Char.is_alphanum (Char.of_int_exn code)) || code = Char.to_int '_'
      then Identifier
      else Punctuation)
;;

let next text p = Option.value_exn (B.next_boundary text p)
let prev text p = Option.value_exn (B.prev_boundary text p)
let class_at text word p = char_class word (B.uchar_at text p)
let is_lf text p = p < B.length text && Uchar.to_scalar (B.uchar_at text p) = 0x0A

let is_empty_line_start text p =
  (p = 0 || is_lf text (prev text p)) && (p = B.length text || is_lf text p)
;;

let is_word_start text word p =
  p < B.length text
  &&
  let c = class_at text word p in
  (not (equal_char_class c Blank))
  && (p = 0 || not (equal_char_class (class_at text word (prev text p)) c))
;;

let is_word_end text word p =
  p < B.length text
  &&
  let c = class_at text word p in
  let q = next text p in
  (not (equal_char_class c Blank))
  && (q = B.length text || not (equal_char_class (class_at text word q) c))
;;

(* One step of each word motion, or [None] when there is nowhere further to go. *)

let word_forward text word p =
  if p >= B.length text
  then None
  else (
    let rec scan q =
      if q >= B.length text || is_word_start text word q || is_empty_line_start text q
      then q
      else scan (next text q)
    in
    Some (scan (next text p)))
;;

let word_backward text word p =
  if p = 0
  then None
  else (
    let rec scan q =
      if q = 0 || is_word_start text word q || is_empty_line_start text q
      then q
      else scan (prev text q)
    in
    Some (scan (prev text p)))
;;

let word_end text word p =
  let rec scan q =
    if q >= B.length text
    then None
    else if is_word_end text word q
    then Some q
    else scan (next text q)
  in
  if p >= B.length text then None else scan (next text p)
;;

let rec repeat n p ~step =
  if n = 0
  then p
  else (
    match step p with
    | None -> p
    | Some q -> repeat (n - 1) q ~step)
;;

(* Lines *)

let first_nonblank text line =
  let stop = B.line_end text line in
  let rec scan p =
    if p < stop
       && (let code = Uchar.to_scalar (B.uchar_at text p) in
           code = 0x20 || code = 0x09)
    then scan (p + 1)
    else p
  in
  scan (B.line_start text line)
;;

(* The last character other than space or TAB, or the line start for a blank line. *)
let last_nonblank text line =
  let start = B.line_start text line in
  let is_blank p =
    let code = Uchar.to_scalar (B.uchar_at text p) in
    code = 0x20 || code = 0x09
  in
  (* [p] is the start of a character that is not blank, or the line start. *)
  let rec scan p = if p > start && is_blank p then scan (prev text p) else p in
  let stop = B.line_end text line in
  if stop = start then start else scan (prev text stop)
;;

(* Matching delimiters. They are ASCII, so scanning bytes is safe: no byte of a
   multibyte UTF-8 sequence is ASCII, and every match is a code-point boundary. *)

let mate = function
  | '(' -> Some ')'
  | ')' -> Some '('
  | '[' -> Some ']'
  | ']' -> Some '['
  | '{' -> Some '}'
  | '}' -> Some '{'
  | _ -> None
;;

let is_opening = function
  | '(' | '[' | '{' -> true
  | _ -> false
;;

let matching_delimiter text ~cursor : (int, Failure.t) Result.t =
  let s = B.to_string text in
  let stop = B.line_end text (B.line_of_offset text cursor) in
  let rec find i =
    if i >= stop then None else if Option.is_some (mate s.[i]) then Some i else find (i + 1)
  in
  match find cursor with
  | None -> Error No_delimiter
  | Some start ->
    let first = s.[start] in
    (* Scanning away from [first]: delimiters facing the same way as [first] open a
       nesting level, the others close one. [stack] holds the open ones, innermost
       first, starting with [first]. *)
    let forward = is_opening first in
    let step = if forward then 1 else -1 in
    let rec scan i stack =
      if i < 0 || i >= String.length s
      then Error (Failure.Unmatched first)
      else (
        let c = s.[i] in
        match mate c with
        | None -> scan (i + step) stack
        | Some m ->
          if Bool.equal (is_opening c) forward
          then scan (i + step) (c :: stack)
          else (
            match stack with
            | top :: rest when Char.equal top m ->
              if List.is_empty rest then Ok i else scan (i + step) rest
            | _ -> Error (Unmatched first)))
    in
    scan (start + step) [ first ]
;;

let clamp_line text line = Int.clamp_exn line ~min:0 ~max:(B.line_count text - 1)

let destination text t ~cursor ~preferred_column ~count : (int, Failure.t) Result.t =
  let n = Option.value count ~default:1 in
  let line = B.line_of_offset text cursor in
  match t with
  | Left ->
    Ok (B.offset_of_column text ~line (Int.max 0 (B.column_of_offset text cursor - n)))
  | Right ->
    (* [offset_of_column] stops at the line end. *)
    Ok (B.offset_of_column text ~line (B.column_of_offset text cursor + n))
  | Up | Down ->
    let target = clamp_line text (if equal t Up then line - n else line + n) in
    Ok
      (if target = line
       then cursor
       else B.offset_of_column text ~line:target preferred_column)
  | Word_forward word -> Ok (repeat n cursor ~step:(word_forward text word))
  | Word_backward word -> Ok (repeat n cursor ~step:(word_backward text word))
  | Word_end word -> Ok (repeat n cursor ~step:(word_end text word))
  | Line_start -> Ok (B.line_start text line)
  | First_nonblank -> Ok (first_nonblank text line)
  | First_nonblank_down -> Ok (first_nonblank text (clamp_line text (line + n - 1)))
  | Line_end -> Ok (B.line_end text (clamp_line text (line + n - 1)))
  | Last_nonblank -> Ok (last_nonblank text (clamp_line text (line + n - 1)))
  | First_line ->
    Ok
      (first_nonblank
         text
         (Option.value_map count ~default:0 ~f:(fun n -> clamp_line text (n - 1))))
  | Last_line ->
    Ok
      (first_nonblank
         text
         (Option.value_map count ~default:(B.line_count text - 1) ~f:(fun n ->
            clamp_line text (n - 1))))
  | Matching_delimiter -> matching_delimiter text ~cursor
;;
