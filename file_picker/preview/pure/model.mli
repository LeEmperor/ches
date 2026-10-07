open! Core

(** Hard limits, not configurable upwards. Raw prefix bytes include LF delimiters. *)
val max_bytes : int
val max_lines : int
type source = Disk | Buffer of { revision : int } [@@deriving sexp_of, equal]
type truncation = { bytes : bool; lines : bool; utf8_boundary : bool }
[@@deriving sexp_of, equal]
(** Cap hits are conservatively truncated, even if the file ends exactly there:
    no extra byte/line is read to prove EOF. [utf8_boundary] records removed bytes.
    Text is raw valid UTF-8 (CR/tab/control characters may remain); presentation
    MUST use the shared safe display-cell utilities, never emit raw terminal text.
    [lines] excludes LF and has no extra empty row after a final LF. *)
type payload = private
  { source : source; text : string; lines : string list; bytes_read : int }
[@@deriving sexp_of]
type unsupported = Binary | Encoding | Special_file [@@deriving sexp_of, equal]
type state =
  | Loading
  | Ready of payload
  | Truncated of payload * truncation
  | Empty of source
  | Missing
  | Unreadable of string
  | Unsupported of unsupported
[@@deriving sexp_of]
type request =
  { session : Ches_file_picker.Model.Discovery.request
  ; selected : Ches_file_picker.Model.Candidate.Id.t
  ; generation : int
  }
[@@deriving sexp_of, equal]
type snapshot = { request : request; state : state } [@@deriving sexp_of]

(** A second installation guard for frontend events queued before selection/close.
    [None] means inactive; never install a delivery merely because its path matches. *)
val accept : expected:request option -> snapshot -> bool

(** [read] must honor the requested length, return 0 at EOF, and not read ahead.
    Each call requests <= remaining byte AND LF budgets, so even newline-only
    input stops at line 100 without reading line 101. No unbounded line reader.
    [cancelled] is checked between reads. Cancellation returns [None]. *)
val collect
  : source:source -> cancelled:(unit -> bool)
  -> read:(Bytes.t -> len:int -> int) -> state option

(** Bounded copy from immutable current text; never [to_string]/[line_text] on a
    potentially huge document/line. Does not retain the supplied text buffer. *)
val of_buffer : revision:int -> Ches_core.Text_buffer.t -> state
