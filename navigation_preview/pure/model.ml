open! Core
module L = Ches_error.Language_query
module T = Ches_core.Text_buffer

type request = { generation : int; target : L.target } [@@deriving sexp_of]
type source = Buffer of { revision : int } | Disk of { stamp : string option } [@@deriving sexp_of]
type highlight = { start : int; stop : int } [@@deriving sexp_of]
type line = { text : string; highlights : highlight list; truncated : bool } [@@deriving sexp_of]
type payload = { source : source; first_line : int; lines : line list; truncated : bool } [@@deriving sexp_of]
type state = Loading | Ready of payload | Missing | Unreadable of string
  | Unsupported of string | Limit of string | Invalid_target of string | Cancelled
[@@deriving sexp_of]
type snapshot = { request : request; state : state } [@@deriving sexp_of]

let max_scan_bytes = 8 * 1024 * 1024
let max_line_bytes = 4096
let max_output_bytes = 64 * 1024
let max_lines = 32
exception Stop of state
let invalid () = raise (Stop (Invalid_target "Selection coordinates are outside the source"))
let limit () = raise (Stop (Limit "Target exceeds preview budget"))
let check (target : L.target) =
  let a = target.selection.start and b = target.selection.stop in
  if a.line < 0 || a.character < 0 || b.line < a.line || b.character < 0
     || (a.line = b.line && b.character < a.character) then invalid ()
;;
let first (target : L.target) = Int.max 0 (target.selection.start.line - 3)
let last target =
  let n = target.L.selection.start.line in n + Int.min 20 (Int.max_value - n)

let prefix text =
  let rec trim n =
    if n = 0 || Stdlib.String.is_valid_utf_8 (String.prefix text n) then String.prefix text n
    else trim (n - 1)
  in trim (String.length text)
;;

let finish ~source ~(target : L.target) ~first_line ~eof raw =
  let a = target.selection.start and b = target.selection.stop in
  if first_line + List.length raw <= a.line then invalid ();
  if eof && first_line + List.length raw <= b.line then invalid ();
  let lines = List.mapi raw ~f:(fun i (text, truncated) ->
    let number = first_line + i in
    let offset character =
      match L.offset target.encoding ~text { line = 0; character } with
      | Some n -> n
      | None -> if truncated then limit () else invalid ()
    in
    let start = if number = a.line then offset a.character else 0 in
    let stop = if number = b.line then offset b.character else String.length text in
    let highlights = if number < a.line || number > b.line then []
      else if number = b.line && b.line > a.line && b.character = 0 then []
      else [{ start; stop }] in
    { text; highlights; truncated }) in
  Ready { source; first_line; lines;
          truncated = not eof || List.exists lines ~f:(fun l -> l.truncated) }
;;

let of_buffer ~revision target buffer =
  try
    check target;
    if target.L.selection.start.line >= T.line_count buffer then invalid ();
    if target.L.selection.stop.line >= T.line_count buffer then invalid ();
    let first_line = first target in
    let count = Int.min (last target) (T.line_count buffer - 1) - first_line + 1 in
    let budget = ref max_output_bytes in
    let raw = List.init count ~f:(fun i ->
      let n = first_line + i in
      let start = T.line_start buffer n in
      let length = T.line_end buffer n - start in
      let take = Int.min length (Int.min max_line_bytes !budget) in
      let stop = ref (start + take) in
      while not (T.is_boundary buffer !stop) do Int.decr stop done;
      let text = T.slice buffer ~pos:start ~len:(!stop - start) in
      budget := !budget - String.length text;
      text, String.length text < length) in
    finish ~source:(Buffer { revision }) ~target ~first_line
      ~eof:(first_line + count = T.line_count buffer) raw
  with Stop state -> state
;;

let collect ~source ~target ~cancelled ~read =
  try
    check target;
    let first_line = first target in
    let line_number = ref 0 and scanned = ref 0 and output = ref 0 in
    let raw = ref [] and body = Buffer.create max_line_bytes in
    let line_bytes = ref 0 and previous_cr = ref false in
    let remaining = ref 0 and low = ref 0x80 and high = ref 0xbf in
    let validate c =
      let n = Char.to_int c in
      if n = 0 then raise (Stop (Unsupported "Binary source (NUL byte)"));
      if !remaining > 0 then (
        if n < !low || n > !high then raise (Stop (Unsupported "Invalid UTF-8"));
        Int.decr remaining; low := 0x80; high := 0xbf)
      else if n >= 0x80 then (
        low := 0x80; high := 0xbf;
        if n >= 0xc2 && n <= 0xdf then remaining := 1
        else if n >= 0xe0 && n <= 0xef then (
          remaining := 2; if n = 0xe0 then low := 0xa0;
          if n = 0xed then high := 0x9f)
        else if n >= 0xf0 && n <= 0xf4 then (
          remaining := 3; if n = 0xf0 then low := 0x90;
          if n = 0xf4 then high := 0x8f)
        else raise (Stop (Unsupported "Invalid UTF-8")))
    in
    let emit () =
      if !line_number >= first_line then (
        let text = Buffer.contents body in
        let text = if !previous_cr && String.is_suffix text ~suffix:"\r"
          then String.drop_suffix text 1 else text in
        let text = prefix text in
        output := !output + String.length text;
        raw := (text, !line_bytes - (if !previous_cr then 1 else 0) > String.length text) :: !raw);
      Buffer.clear body; line_bytes := 0; previous_cr := false;
      Int.incr line_number
    in
    let bytes = Bytes.create 8192 in
    let rec loop () =
      if cancelled () then raise (Stop Cancelled);
      if !scanned >= max_scan_bytes then limit ();
      let len = Int.min (Bytes.length bytes) (max_scan_bytes - !scanned) in
      let got = read bytes ~pos:0 ~len in
      if got < 0 || got > len then invalid_arg "Navigation preview read count";
      if got = 0 then (
        if !previous_cr then raise (Stop (Unsupported "Bare CR line endings"));
        if !remaining <> 0 then raise (Stop (Unsupported "Invalid UTF-8"));
        emit ();
        finish ~source ~target ~first_line ~eof:true (List.rev !raw))
      else (
        scanned := !scanned + got;
        for i = 0 to got - 1 do
          if i mod 256 = 0 && cancelled () then raise (Stop Cancelled);
          let c = Bytes.get bytes i in
          if !previous_cr && not (Char.equal c '\n') then
            raise (Stop (Unsupported "Bare CR line endings"));
          validate c;
          if Char.equal c '\n' then (
            emit ();
            if !line_number > last target then
              raise (Stop (finish ~source ~target ~first_line ~eof:false (List.rev !raw))))
          else (
            Int.incr line_bytes;
            previous_cr := Char.equal c '\r';
            if !line_number >= first_line && Buffer.length body < max_line_bytes
               && !output + Buffer.length body < max_output_bytes then Buffer.add_char body c)
        done;
        loop ())
    in loop ()
  with Stop state -> state
