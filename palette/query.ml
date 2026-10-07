open! Core

let is_control scalar = scalar <= 0x1F || (scalar >= 0x7F && scalar <= 0x9F)

let sanitize s =
  let buffer = Buffer.create (String.length s) in
  let rec loop pos =
    if pos < String.length s
    then
      if String.is_substring_at s ~pos ~substring:"\r\n"
      then (Buffer.add_char buffer ' '; loop (pos + 2))
      else (
        let decoded = Stdlib.String.get_utf_8_uchar s pos in
        let u = Stdlib.Uchar.utf_decode_uchar decoded in
        (match Uchar.to_scalar u with
         | 0x0A | 0x0D | 0x09 -> Buffer.add_char buffer ' '
         | scalar when is_control scalar -> ()
         | _ -> Stdlib.Buffer.add_utf_8_uchar buffer u);
        loop (pos + Stdlib.Uchar.utf_decode_length decoded))
  in
  loop 0;
  Buffer.contents buffer
;;

let append query text = query ^ sanitize text

let backspace query =
  match String.rfindi query ~f:(fun _ c -> Char.to_int c land 0xC0 <> 0x80) with
  | None -> query
  | Some start -> String.prefix query start
;;

let delete_word query =
  let trimmed = String.rstrip query ~drop:(Char.equal ' ') in
  let keep = Option.value_map (String.rindex trimmed ' ') ~default:0 ~f:(fun i -> i + 1) in
  String.prefix trimmed keep
;;
