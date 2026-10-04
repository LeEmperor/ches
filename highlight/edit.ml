open! Core

type point = { row : int; column : int } [@@deriving sexp_of, equal, compare]
type t =
  { start_byte : int
  ; old_end_byte : int
  ; new_end_byte : int
  ; start_point : point
  ; old_end_point : point
  ; new_end_point : point
  }
[@@deriving sexp_of, equal]

let boundary source offset =
  offset = String.length source || Char.to_int source.[offset] land 0xc0 <> 0x80
;;
let point source stop =
  let row = ref 0 and column = ref 0 in
  for i = 0 to stop - 1 do
    if Char.equal source.[i] '\n' then (incr row; column := 0) else incr column
  done;
  { row = !row; column = !column }
;;
let between ~old_source ~new_source =
  if not (Stdlib.String.is_valid_utf_8 old_source && Stdlib.String.is_valid_utf_8 new_source)
  then invalid_arg "Edit.between: invalid UTF-8";
  if String.equal old_source new_source then None
  else (
    let old_length = String.length old_source and new_length = String.length new_source in
    let start = ref 0 in
    while !start < Int.min old_length new_length
          && Char.equal old_source.[!start] new_source.[!start] do incr start done;
    while not (boundary old_source !start && boundary new_source !start) do decr start done;
    let suffix = ref 0 in
    while !suffix < Int.min (old_length - !start) (new_length - !start)
          && Char.equal old_source.[old_length - !suffix - 1] new_source.[new_length - !suffix - 1]
    do incr suffix done;
    while not (boundary old_source (old_length - !suffix)
               && boundary new_source (new_length - !suffix)) do decr suffix done;
    let old_end_byte = old_length - !suffix and new_end_byte = new_length - !suffix in
    Some { start_byte = !start; old_end_byte; new_end_byte
         ; start_point = point old_source !start
         ; old_end_point = point old_source old_end_byte
         ; new_end_point = point new_source new_end_byte })
;;
