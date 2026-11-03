open! Core

type request = { generation : int; target : Ches_error.Language_query.target }
[@@deriving sexp_of]
type source = Buffer of { revision : int } | Disk of { stamp : string option }
[@@deriving sexp_of]
type highlight = { start : int; stop : int } [@@deriving sexp_of]
(** Highlight offsets are half-open UTF-8 bytes in [text]; equal offsets mark a
    zero-width selection. Text excludes LF and CRLF terminators. *)
type line = { text : string; highlights : highlight list; truncated : bool }
[@@deriving sexp_of]
type payload = { source : source; first_line : int; lines : line list; truncated : bool }
[@@deriving sexp_of]
type state = Loading | Ready of payload | Missing | Unreadable of string
  | Unsupported of string | Limit of string | Invalid_target of string | Cancelled
[@@deriving sexp_of]
type snapshot = { request : request; state : state } [@@deriving sexp_of]

val max_scan_bytes : int
val max_line_bytes : int
val max_output_bytes : int
val max_lines : int

(** Indexed, bounded copying, without whole-buffer conversion or whole-line copies. *)
val of_buffer : revision:int -> Ches_error.Language_query.target -> Ches_core.Text_buffer.t -> state

(** Synchronous worker-side collector; no I/O dependency. [read bytes ~pos ~len]
    returns 0 at EOF, or a count in [1,len]. Exceptions propagate to the host,
    which maps file errors to Missing/Unreadable. Cancellation is polled before
    each read and during scanning. Reads/scans at most 8 MiB; retains at most
    32 lines, 4096 bytes per line and 64 KiB total. Window starts up to three
    lines before selection.start, with up to twenty lines below. A target not
    reached within the scan budget returns Limit. Disk stamps belong to host. *)
val collect
  : source:source
  -> target:Ches_error.Language_query.target
  -> cancelled:(unit -> bool)
  -> read:(bytes -> pos:int -> len:int -> int)
  -> state
