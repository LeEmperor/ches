open! Core
let max_bytes = 64 * 1024
let max_lines = 100
type source = Disk | Buffer of { revision : int } [@@deriving sexp_of, equal]
type truncation = { bytes : bool; lines : bool; utf8_boundary : bool }
[@@deriving sexp_of, equal]
type payload = { source : source; text : string; lines : string list; bytes_read : int }
[@@deriving sexp_of]
type unsupported = Binary | Encoding | Special_file [@@deriving sexp_of, equal]
type state = Loading | Ready of payload | Truncated of payload * truncation
  | Empty of source | Missing | Unreadable of string | Unsupported of unsupported
[@@deriving sexp_of]
type request =
  { session : Ches_file_picker.Model.Discovery.request
  ; selected : Ches_file_picker.Model.Candidate.Id.t; generation : int }
[@@deriving sexp_of, equal]
type snapshot = { request : request; state : state } [@@deriving sexp_of]
let accept ~expected snapshot = Option.exists expected ~f:(equal_request snapshot.request)

(* Only an incomplete, otherwise legal final scalar may be removed at the byte
   cap. Malformed continuations/overlongs/surrogates remain encoding errors. *)
let valid_prefix raw ~byte_cap =
  let n = String.length raw in
  let rec loop i =
    if i = n then Ok (n, false)
    else if Char.equal raw.[i] '\000' then Error Binary
    else
      let d = Stdlib.String.get_utf_8_uchar raw i in
      if Stdlib.Uchar.utf_decode_is_valid d
      then loop (i + Stdlib.Uchar.utf_decode_length d)
      else (
        let lead = Char.to_int raw.[i] in
        let needed = if lead >= 0xc2 && lead <= 0xdf then 2
          else if lead >= 0xe0 && lead <= 0xef then 3
          else if lead >= 0xf0 && lead <= 0xf4 then 4 else 0 in
        let tail_ok = ref true in
        for j = i + 1 to n - 1 do
          let c = Char.to_int raw.[j] in
          if c < 0x80 || c > 0xbf
             || (j = i + 1 && ((lead = 0xe0 && c < 0xa0)
                 || (lead = 0xed && c > 0x9f) || (lead = 0xf0 && c < 0x90)
                 || (lead = 0xf4 && c > 0x8f))) then tail_ok := false
        done;
        if byte_cap && needed > n - i && needed > 0 && !tail_ok
        then Ok (i, true) else Error Encoding)
  in loop 0
;;
let finish ~source raw ~bytes ~lines =
  match valid_prefix raw ~byte_cap:bytes with
  | Error reason -> Unsupported reason
  | Ok (len, utf8_boundary) ->
    let text = String.prefix raw len in
    let rows = String.split text ~on:'\n' in
    (* LF terminates the preceding row; no invented empty row after a final LF. *)
    let rows = if String.is_suffix text ~suffix:"\n" then List.drop_last_exn rows else rows in
    let payload = { source; text; lines = rows; bytes_read = String.length raw } in
    if bytes || lines then Truncated (payload, { bytes; lines; utf8_boundary })
    else if String.is_empty text then Empty source else Ready payload
;;
let collect ~source ~cancelled ~read =
  let scratch = Bytes.create max_lines in
  let raw = Buffer.create 4096 in
  let lf = ref 0 in
  let rec loop () =
    if cancelled () then None
    else
      let bytes = Buffer.length raw >= max_bytes and lines = !lf >= max_lines in
      if bytes || lines then Some (finish ~source (Buffer.contents raw) ~bytes ~lines)
      else (
        let len = Int.min (max_bytes - Buffer.length raw) (max_lines - !lf) in
        let got = read scratch ~len in
        if got < 0 || got > len then invalid_arg "Preview read exceeded requested bound";
        if got = 0 then Some (finish ~source (Buffer.contents raw) ~bytes:false ~lines:false)
        else (
          for i = 0 to got - 1 do if Char.equal (Bytes.get scratch i) '\n' then incr lf done;
          Buffer.add_subbytes raw scratch ~pos:0 ~len:got;
          loop ()))
  in loop ()
;;
let of_buffer ~revision buffer =
  let module Text = Ches_core.Text_buffer in
  let line_end = if Text.line_count buffer > max_lines then Text.line_start buffer max_lines
    else Text.length buffer in
  let capped = Int.min max_bytes line_end in
  let rec boundary n = if Text.is_boundary buffer n then n else boundary (n - 1) in
  let len = boundary capped in
  let raw = Text.slice buffer ~pos:0 ~len in
  let result = finish ~source:(Buffer { revision }) raw
    ~bytes:(capped = max_bytes && Text.length buffer >= max_bytes)
    ~lines:(line_end = capped && Text.line_count buffer > max_lines) in
  match result with
  | Truncated (payload, reason) ->
    Truncated ({ payload with bytes_read = capped }, { reason with utf8_boundary = len < capped })
  | _ -> result
;;
