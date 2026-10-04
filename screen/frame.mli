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
  ; cursor : Cursor.t option
  (** [None] when there is no text cell to put it in, while the smear animation runs,
      and during a block insert, whose cursor is drawn as a styled cell instead
      ([Style.Overlay.Insert_cursor]) so that the theme can color it. *)
  ; smear : (int * int) list (** Filled cells for the animated-cursor overlay. *)
  }
[@@deriving sexp_of]

(** Uses the controller's cached current highlights by default, with no parsing.
    An optional override supplies an expected current key and snapshot. The caller
    owns identity/configuration and must supply the current key, never the key
    copied from an obsolete result. Mismatched keys or editor revisions fall back
    to plain text. No provider work occurs here. *)
val render
  :  ?highlights:(Ches_highlight.Snapshot.Key.t * Ches_highlight.Snapshot.t)
  -> Ui_state.t -> width:int -> height:int -> t

(** The screen as text, one line per row, each ending in [|] to show the width, then
    the cursor. For tests. *)
val to_string : t -> string

(** Each row's spans with their styles. For tests. *)
val to_string_styled : t -> string
