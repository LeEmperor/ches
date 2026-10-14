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

module For_testing = struct
  type work =
    { mutable full_scan_bytes : int
    ; mutable inserted_scan_bytes : int
    ; mutable destination_bytes : int
    ; mutable destinations : int
    }
  let active = ref None
  let record f = Option.iter !active ~f
  let measure f =
    let work = { full_scan_bytes = 0; inserted_scan_bytes = 0; destination_bytes = 0; destinations = 0 } in
    let previous = !active in
    active := Some work;
    Exn.protect ~f:(fun () -> f (), work) ~finally:(fun () -> active := previous)
  ;;
end

(* Immutable starts, updated from the replaced range and inserted bytes. *)
type t =
  { text : string
  ; line_starts : int array
  ; identity_scope : string option
  ; identities : (int * string) list
  ; identity_bytes : int
  ; mutable layouts : (int * Cell_layout.Width.t * Cell_layout.Index.t) list
  }

let sexp_of_t t = [%sexp (t.text : string)]
let equal t1 t2 = phys_equal t1 t2 || ((phys_equal t1.text t2.text || String.equal t1.text t2.text)
  && Option.equal String.equal t1.identity_scope t2.identity_scope
   && (phys_equal t1.identities t2.identities || [%equal: (int * string) list] t1.identities t2.identities))

let compute_line_starts text =
  For_testing.record (fun w -> w.full_scan_bytes <- w.full_scan_bytes + 2 * String.length text);
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
let of_valid_string text = { text; line_starts = compute_line_starts text; identity_scope = None; identities = []; identity_bytes = 0; layouts = [] }
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
  let identity_bytes =
    Option.value_map t.identity_scope ~default:0 ~f:(fun s -> 24 + String.length s)
    + List.fold identities ~init:0 ~f:(fun bytes (_, token) -> bytes + 72 + String.length token)
  in
  { t with identities; identity_bytes }
;;
let identity_scope t = t.identity_scope
let identities t = t.identities
let with_identities t ~scope identities = normalize_identities { t with identity_scope = Some scope; identities }
let empty = of_valid_string ""
let of_string text = Result.map (validate text) ~f:(fun () -> of_valid_string text)
let to_string t = t.text
let length t = String.length t.text
let retained_bytes t = 128 + String.length t.text + (8 * Array.length t.line_starts) + t.identity_bytes
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

let line_index t offset =
  let rec search lo hi =
    if lo = hi then lo else
      let mid = (lo + hi + 1) / 2 in
      if t.line_starts.(mid) <= offset then search mid hi else search lo (mid - 1)
  in
  search 0 (Array.length t.line_starts - 1)
;;

let replace_valid ?(identities = []) ?(anchor_affinity = `Right)
    ?(linewise = false) ?(preserve_identities = false) t ~pos ~len s =
  let inserted = String.length s in
  if len = 0 && inserted = 0
  then if linewise then normalize_identities { t with identities = List.filter t.identities ~f:(fun (anchor, _) -> anchor <> pos) } else t
  else (
    let stop = pos + len in
    if inserted > Sys.max_string_length - (length t - len)
    then invalid_arg "Text_buffer.replace: result is too large";
    let first = line_index t pos and last = line_index t stop in
    let added = String.count s ~f:(Char.equal '\n') in
    For_testing.record (fun w -> w.inserted_scan_bytes <- w.inserted_scan_bytes + inserted);
    let delta = inserted - len in
    let line_starts =
      if delta = 0 && first = last && added = 0 then t.line_starts
      else (
        let starts = Array.create ~len:(Array.length t.line_starts - (last - first) + added) 0 in
        Array.blit ~src:t.line_starts ~src_pos:0 ~dst:starts ~dst_pos:0 ~len:(first + 1);
        let next = ref (first + 1) in
        For_testing.record (fun w -> w.inserted_scan_bytes <- w.inserted_scan_bytes + inserted);
        String.iteri s ~f:(fun i c -> if Char.equal c '\n' then (starts.(!next) <- pos + i + 1; incr next));
        for i = last + 1 to Array.length t.line_starts - 1 do
          starts.(!next) <- t.line_starts.(i) + delta;
          incr next
        done;
        starts)
    in
    let size = length t + delta in
    let dst = Stdlib.Bytes.create size in
    For_testing.record (fun w -> w.destinations <- w.destinations + 1; w.destination_bytes <- w.destination_bytes + size);
    Stdlib.Bytes.blit_string t.text 0 dst 0 pos;
    Stdlib.Bytes.blit_string s 0 dst pos inserted;
    Stdlib.Bytes.blit_string t.text stop dst (pos + inserted) (length t - stop);
    let text = Stdlib.Bytes.unsafe_to_string dst in
    let existing = List.filter_map t.identities ~f:(fun (anchor, token) ->
      let line = line_index t anchor in
      let line_end = if line + 1 = Array.length t.line_starts then length t else t.line_starts.(line + 1) - 1 in
      if (len > 0 && not preserve_identities && anchor >= pos && anchor < stop && (linewise || line_end < stop))
         || (len = 0 && linewise && anchor = pos)
      then None
      else (
        (* Normalize in the deleted document before applying insertion affinity. *)
        let anchor = if len > 0 && anchor >= pos && anchor <= stop then t.line_starts.(first)
          else if anchor > stop then anchor - len else anchor in
        let anchor = if anchor > pos || (anchor = pos && added > 0 && Poly.equal anchor_affinity `Right)
          then anchor + inserted else anchor in
        Some (anchor, token))) in
    { text; line_starts; identity_scope = t.identity_scope
    ; identities = existing @ (if inserted = 0 then [] else List.map identities ~f:(fun (offset, token) -> pos + offset, token))
    ; identity_bytes = 0; layouts = [] }
    |> normalize_identities)
;;

let replace ?identities ?anchor_affinity ?linewise ?preserve_identities t ~pos ~len s =
  check_range t ~fn:"replace" ~pos ~len;
  Result.map (validate s) ~f:(fun () -> replace_valid ?identities ?anchor_affinity ?linewise ?preserve_identities t ~pos ~len s)
;;

let insert ?identities ?anchor_affinity t ~at s =
  check_boundary t ~fn:"insert" at;
  Result.map (validate s) ~f:(fun () -> replace_valid ?identities ?anchor_affinity t ~pos:at ~len:0 s)
;;

let delete ?linewise ?preserve_identities t ~pos ~len =
  check_range t ~fn:"delete" ~pos ~len;
  replace_valid ?linewise ?preserve_identities t ~pos ~len ""
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

let line_layout t ~width line =
  match List.find t.layouts ~f:(fun (l, w, _) -> l = line && phys_equal w width) with
  | Some (_, _, layout) -> layout
  | None ->
    let layout = Cell_layout.Index.create ~width t.text
      ~start:(line_start t line) ~stop:(line_end t line) in
    (* Per immutable text snapshot: 64 lines/width identities, no global roots.
       Edits construct a new buffer with an empty cache. *)
    t.layouts <- (line, width, layout) :: List.take t.layouts 63;
    layout
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

(* Scalar navigation also uses sparse checkpoints. This stable function is an
   explicit separate width identity for callers without a frontend width. *)
let scalar_width _ = 1

let column_of_offset t offset =
  let line = line_of_offset t offset in
  Cell_layout.Index.scalar_column (line_layout t ~width:scalar_width line)
    ~pos:(offset - line_start t line)
;;

let offset_of_column t ~line column =
  if column < 0 then invalid_argf "Text_buffer.offset_of_column: column %d < 0" column ();
  line_start t line + Cell_layout.Index.pos_of_scalar_column
    (line_layout t ~width:scalar_width line) column
;;
