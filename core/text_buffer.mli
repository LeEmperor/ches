(** Immutable document text: valid UTF-8 with LF line endings.

    The representation is abstract so it can later be replaced by a rope or piece
    tree without changing callers. Whole-text access ({!of_string}, {!to_string}) is
    intended for loading and saving; everything else works on offsets and lines.

    {2 Conventions}

    - Offsets are zero-based {b byte} offsets in [\[0, length t\]].
    - A {i boundary} is an offset where a code point starts, or [length t]. Every
      offset argument must be a boundary.
    - Lines are zero-based, in [\[0, line_count t)]. There is always at least one
      line: the empty buffer is one empty line, and a trailing LF starts an empty
      final line. So ["ab\n"] has lines ["ab"] and [""].
    - A line's end excludes its LF. The LF byte at offset [line_end t i] belongs to
      line [i].

    {2 Errors}

    - Text that is not accepted (see {!validate}) is rejected with
      [Error Invalid_text.t]. This is an expected outcome: it comes from files and
      user input.
    - An offset, length, or line index that is out of range or not on a boundary is
      a programming error and raises [Invalid_argument]. No operation is ever
      partially applied. *)

open! Core

module Invalid_text : sig
  type reason =
    | Invalid_utf8
    | Nul
    | Crlf
    | Bare_cr
  [@@deriving sexp_of, equal]

  (** [offset] is the byte offset of the offending byte within the string that was
      validated (for {!insert}, the inserted string, not the buffer). *)
  type t =
    { reason : reason
    ; offset : int
    }
  [@@deriving sexp_of, equal]

  (** e.g. ["invalid UTF-8 at byte offset 3"] *)
  val to_string_hum : t -> string
end

(** Accepts valid UTF-8 containing no NUL and no CR bytes. Reports the first
    offending byte. *)
val validate : string -> (unit, Invalid_text.t) Result.t

type t [@@deriving sexp_of]

(** Equality includes protected identity metadata, when present. *)
val equal : t -> t -> bool

val empty : t
val of_string : string -> (t, Invalid_text.t) Result.t

(** The exact bytes of the text. *)
val to_string : t -> string

(** Protected row anchors carried by immutable snapshots, never by visible text.
    Tokens are opaque to the text engine; duplicate anchors remain detectable. *)
val identity_scope : t -> string option
val identities : t -> (int * string) list
val with_identities : t -> scope:string -> (int * string) list -> t

(** Length in bytes. *)
val length : t -> int

(** {2 Editing} *)

(** [insert t ~at s] inserts [s] at boundary [at]. Returns [Error] if [s] is not
    accepted by {!validate}. Raises if [at] is not a boundary. When inserting LF
    at a protected anchor, [anchor_affinity] specifies whether its existing row
    stays left of the inserted text or moves right (default [`Right]). Row-opening
    and linewise-paste operations choose affinity explicitly. *)
val insert : ?identities:(int * string) list -> ?anchor_affinity:[ `Left | `Right ] -> t -> at:int -> string -> (t, Invalid_text.t) Result.t

(** [delete t ~pos ~len] removes bytes [\[pos, pos + len)]. Both ends must be
    boundaries and [len >= 0]. Whole covered rows lose their identity; deleting
    name bytes alone retains it. [linewise] also removes the final unterminated
    row's identity. [preserve_identities] keeps selected anchors for a change
    operation, leaving multiple joined identities detectable by validation. *)
val delete : ?linewise:bool -> ?preserve_identities:bool -> t -> pos:int -> len:int -> t

(** [slice t ~pos ~len] is bytes [\[pos, pos + len)]. Same requirements as
    {!delete}. *)
val slice : t -> pos:int -> len:int -> string

(** {2 Lines} *)

(** At least 1. *)
val line_count : t -> int

(** Offset of the first byte of [line]. *)
val line_start : t -> int -> int

(** Offset just past the last byte of [line], excluding its LF. *)
val line_end : t -> int -> int

(** The text of [line], without its LF. *)
val line_text : t -> int -> string

(** The line containing boundary [offset]. An offset on an LF byte belongs to the line
    that LF ends; [length t] belongs to the last line. *)
val line_of_offset : t -> int -> int

(** {2 Code points}

    Grapheme clusters are not handled: a combining sequence is several code points. *)

(** Whether [offset] is in [\[0, length t\]] and starts a code point (or is
    [length t]). Never raises. *)
val is_boundary : t -> int -> bool

(** The boundary before [offset], or [None] at [0]. Does not treat LF specially. *)
val prev_boundary : t -> int -> int option

(** The boundary after [offset], or [None] at [length t]. Does not treat LF
    specially. *)
val next_boundary : t -> int -> int option

(** The code point starting at boundary [offset], which must be less than
    [length t]. *)
val uchar_at : t -> int -> Uchar.t

(** Zero-based code-point column of boundary [offset] within its line. *)
val column_of_offset : t -> int -> int

(** [offset_of_column t ~line column] is the boundary [column] code points into
    [line], clamped to [line_end t line] when the line is shorter. Raises if [line] is
    out of range or [column < 0]. *)
val offset_of_column : t -> line:int -> int -> int
