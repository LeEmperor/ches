open! Core

module Invalid_text = struct
  type reason =
    | Invalid_utf8
    | Nul
    | Crlf
    | Bare_cr
  [@@deriving sexp_of, equal]

  type t =
    { reason : reason
    ; offset : int
    }
  [@@deriving sexp_of, equal]

  let to_string_hum { reason; offset } =
    let what =
      match reason with
      | Invalid_utf8 -> "invalid UTF-8"
      | Nul -> "NUL byte"
      | Crlf -> "CRLF line ending (only LF line endings are supported)"
      | Bare_cr -> "carriage return (only LF line endings are supported)"
    in
    sprintf "%s at byte offset %d" what offset
  ;;
end

let validate s : (unit, Invalid_text.t) Result.t =
  let len = String.length s in
  let rec loop i : (unit, Invalid_text.t) Result.t =
    if i >= len
    then Ok ()
    else (
      match s.[i] with
      | '\000' -> Error { reason = Nul; offset = i }
      | '\r' ->
        let reason : Invalid_text.reason =
          if i + 1 < len && Char.equal s.[i + 1] '\n' then Crlf else Bare_cr
        in
        Error { reason; offset = i }
      | c when Char.to_int c < 0x80 -> loop (i + 1)
      | _ ->
        let decode = Stdlib.String.get_utf_8_uchar s i in
        if Stdlib.Uchar.utf_decode_is_valid decode
        then loop (i + Stdlib.Uchar.utf_decode_length decode)
        else Error { reason = Invalid_utf8; offset = i })
  in
  loop 0
;;

(* [line_starts.(i)] is the offset where line [i] begins, so [line_starts.(0) = 0] and
   the array length is the line count. Rebuilt on every edit, which is O(n) like the
   string copy itself. *)
type t =
  { text : string
  ; line_starts : int array
  ; identity_scope : string option
  ; identities : (int * string) list
  }

let sexp_of_t t = [%sexp (t.text : string)]
let equal t1 t2 = String.equal t1.text t2.text
  && Option.equal String.equal t1.identity_scope t2.identity_scope
  && [%equal: (int * string) list] t1.identities t2.identities

let compute_line_starts text =
  let line_starts = Array.create ~len:(1 + String.count text ~f:(Char.equal '\n')) 0 in
  let next_line = ref 1 in
  String.iteri text ~f:(fun i c ->
    if Char.equal c '\n'
    then (
      line_starts.(!next_line) <- i + 1;
      incr next_line));
  line_starts
;;

(* Only for text already known to be valid. *)
let of_valid_string text = { text; line_starts = compute_line_starts text; identity_scope = None; identities = [] }
let normalize_identities t =
  let line_start offset =
    let rec search lo hi =
      if lo = hi then t.line_starts.(lo)
      else
        let mid = (lo + hi + 1) / 2 in
        if t.line_starts.(mid) <= offset then search mid hi else search lo (mid - 1)
    in
    search 0 (Array.length t.line_starts - 1)
  in
  let identities = List.map t.identities ~f:(fun (offset, token) -> line_start offset, token)
    |> List.sort ~compare:(fun (offset, token) (offset', token') ->
      match Int.compare offset offset' with 0 -> String.compare token token' | order -> order) in
  { t with identities }
;;
let identity_scope t = t.identity_scope
let identities t = t.identities
let with_identities t ~scope identities = normalize_identities { t with identity_scope = Some scope; identities }
let empty = of_valid_string ""
let of_string text = Result.map (validate text) ~f:(fun () -> of_valid_string text)
let to_string t = t.text
let length t = String.length t.text
let is_continuation_byte c = Char.to_int c land 0xC0 = 0x80

let is_boundary t offset =
  offset >= 0
  && offset <= length t
  && (offset = length t || not (is_continuation_byte t.text.[offset]))
;;

let check_boundary t ~fn offset =
  if not (is_boundary t offset)
  then
    invalid_argf
      "Text_buffer.%s: offset %d is not a code-point boundary in [0, %d]"
      fn
      offset
      (length t)
      ()
;;

let check_range t ~fn ~pos ~len =
  check_boundary t ~fn pos;
  if len < 0 || len > length t - pos
  then
    invalid_argf
      "Text_buffer.%s: length %d from offset %d is outside [0, %d]"
      fn
      len
      pos
      (length t)
      ();
  check_boundary t ~fn (pos + len)
;;

let insert ?(identities = []) ?(anchor_affinity = `Right) t ~at s =
  check_boundary t ~fn:"insert" at;
  Result.map (validate s) ~f:(fun () ->
    if String.is_empty s
    then t
    else
      let result = of_valid_string
        (String.concat [ String.prefix t.text at; s; String.drop_prefix t.text at ]) in
      let crosses_line = String.contains s '\n' in
      { result with identity_scope = t.identity_scope
        ; identities = List.map t.identities ~f:(fun (pos, token) ->
             (if pos > at || (pos = at && crosses_line && Poly.equal anchor_affinity `Right)
              then pos + String.length s else pos), token)
            @ List.map identities ~f:(fun (pos, token) -> at + pos, token) }
      |> normalize_identities)
;;

let delete ?(linewise = false) ?(preserve_identities = false) t ~pos ~len =
  check_range t ~fn:"delete" ~pos ~len;
  if len = 0
  then if linewise then { t with identities = List.filter t.identities ~f:(fun (anchor, _) -> anchor <> pos) } else t
  else
    let result = of_valid_string (String.prefix t.text pos ^ String.drop_prefix t.text (pos + len)) in
    let stop = pos + len in
    { result with identity_scope = t.identity_scope
      ; identities = List.filter_map t.identities ~f:(fun (anchor, token) ->
          let line_end = String.index_from t.text anchor '\n' |> Option.value ~default:(length t) in
          if not preserve_identities && anchor >= pos && anchor < stop && (linewise || line_end < stop)
          then None
          else Some ((if anchor >= stop then anchor - len else if anchor >= pos then pos else anchor), token)) }
    |> normalize_identities
;;

let slice t ~pos ~len =
  check_range t ~fn:"slice" ~pos ~len;
  String.sub t.text ~pos ~len
;;

let line_count t = Array.length t.line_starts

let check_line t ~fn line =
  if line < 0 || line >= line_count t
  then
    invalid_argf
      "Text_buffer.%s: line %d is outside [0, %d)"
      fn
      line
      (line_count t)
      ()
;;

let line_start t line =
  check_line t ~fn:"line_start" line;
  t.line_starts.(line)
;;

let line_end t line =
  check_line t ~fn:"line_end" line;
  if line = line_count t - 1 then length t else t.line_starts.(line + 1) - 1
;;

let line_text t line =
  let start = line_start t line in
  String.sub t.text ~pos:start ~len:(line_end t line - start)
;;

let line_of_offset t offset =
  check_boundary t ~fn:"line_of_offset" offset;
  (* Last line whose start is <= offset. Invariant: [line_starts.(lo) <= offset] and
     every line after [hi] starts after [offset].

     Hand-rolled because Core's [Array.binary_search] returns a [local_] option in this
     OxCaml version, which could not escape here. Future optimization: revisit with
     mode-aware code (e.g. consume the local result in place) to use the library
     search; note this loop already allocates nothing. *)
  let rec search lo hi =
    if lo = hi
    then lo
    else (
      let mid = (lo + hi + 1) / 2 in
      if t.line_starts.(mid) <= offset then search mid hi else search lo (mid - 1))
  in
  search 0 (line_count t - 1)
;;

let prev_boundary t offset =
  check_boundary t ~fn:"prev_boundary" offset;
  if offset = 0
  then None
  else (
    let rec back i = if is_continuation_byte t.text.[i] then back (i - 1) else i in
    Some (back (offset - 1)))
;;

let next_boundary t offset =
  check_boundary t ~fn:"next_boundary" offset;
  if offset = length t
  then None
  else (
    let lead = Char.to_int t.text.[offset] in
    let width =
      if lead < 0x80 then 1 else if lead < 0xE0 then 2 else if lead < 0xF0 then 3 else 4
    in
    Some (offset + width))
;;

let uchar_at t offset =
  check_boundary t ~fn:"uchar_at" offset;
  if offset = length t then invalid_arg "Text_buffer.uchar_at: offset is the text length";
  Stdlib.Uchar.utf_decode_uchar (Stdlib.String.get_utf_8_uchar t.text offset)
;;

(* O(line length). A rope storing code-point counts could make these logarithmic. *)
let column_of_offset t offset =
  let start = line_start t (line_of_offset t offset) in
  let rec count i acc =
    if i >= offset then acc else count (Option.value_exn (next_boundary t i)) (acc + 1)
  in
  count start 0
;;

let offset_of_column t ~line column =
  if column < 0 then invalid_argf "Text_buffer.offset_of_column: column %d < 0" column ();
  let stop = line_end t line in
  let rec walk i remaining =
    if remaining = 0 || i >= stop
    then i
    else walk (Option.value_exn (next_boundary t i)) (remaining - 1)
  in
  walk (line_start t line) column
;;
