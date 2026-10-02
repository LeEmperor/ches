(** A complete screen, as rows of styled text spans plus the cursor. This is the whole
    visual output of the editor; the terminal frontend only maps styles to colors and
    draws the spans.

    Every row's spans add up to exactly the screen width. Each span's [text] is valid
    UTF-8 without control characters and, by {!Cell_map}'s widths, occupies exactly
    [width] cells; the frontend forces the drawn width to [width] in case the terminal
    library measures a grapheme cluster differently. *)

open! Core

module Span = Span

module Cursor : sig
  type shape =
    | Block (** Normal mode *)
    | Bar (** Insert mode *)
  [@@deriving sexp_of, equal]

  type t =
    { x : int
    ; y : int
    ; shape : shape
    }
  [@@deriving sexp_of, equal]
end

type t =
  { width : int
  ; height : int
  ; rows : Span.t list list
  ; cursor : Cursor.t option (** [None] when there is no text cell to put it in. *)
  }
[@@deriving sexp_of]

val render : Ui_state.t -> width:int -> height:int -> t

(** The screen as text, one line per row, each ending in [|] to show the width, then
    the cursor. For tests. *)
val to_string : t -> string

(** Each row's spans with their styles. For tests. *)
val to_string_styled : t -> string
