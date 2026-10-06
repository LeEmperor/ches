open! Core

(* [text] with each run of matched code points in brackets, e.g. ["[rel]ative"].
   Slicing at the offsets also checks that each starts a code point. *)
let mark text offsets =
  let buffer = Buffer.create (String.length text) in
  let rec loop pos ~open_ offsets =
    match offsets with
    | [] ->
      if open_ then Buffer.add_char buffer ']';
      Buffer.add_string buffer (String.drop_prefix text pos)
    | offset :: rest ->
      if offset > pos
      then (
        if open_ then Buffer.add_char buffer ']';
        Buffer.add_string buffer (String.sub text ~pos ~len:(offset - pos)));
      if offset > pos || not open_ then Buffer.add_char buffer '[';
      let len = Stdlib.Uchar.utf_decode_length (Stdlib.String.get_utf_8_uchar text offset) in
      Buffer.add_string buffer (String.sub text ~pos:offset ~len);
      loop (offset + len) ~open_:true rest
  in
  loop 0 ~open_:false offsets;
  Buffer.contents buffer
;;
