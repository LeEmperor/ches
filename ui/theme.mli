(** The one place colors and font styles are defined: a palette of semantic roles, the
    font styles of each {!Ches_screen.Style.t}, and the attributes they make. One dark
    theme: a near-black neutral gray ground, muted gray chrome, and color kept for the
    mode badge, the dirty marker, feedback, and escape forms. Every label is also
    readable without color. *)

open! Core
open Bonsai_term

module Role : sig
  type t =
    | Backdrop (** Outside the document tile: a shade darker, so the tile stands out. *)
    | Background (** The document tile. *)
    | Foreground
    | Surface (** Status line. *)
    | Muted (** Gutter and secondary text. *)
    | Border
    | Current_line
    | Normal_accent
    | Insert_accent
    | Special (** Escape forms and clip markers. *)
    | Warning
    | Error
    | Block_cursor
    (** During a block insert: the cursor itself, the insertion point the others
        copy. Change it here to recolor it. *)
    | Block_copy (** During a block insert: the insertion points on the other lines. *)
  [@@deriving sexp_of, enumerate]

  val color : t -> Attr.Color.t
end

module Font : sig
  (** A variant of the terminal's font. The terminal chooses the typeface; a style
      only selects among its variants, and a terminal that lacks one (most often
      italic) draws it its own way or not at all. Font styles never change a cell's
      width. *)
  type t =
    | Bold
    | Italic
    | Underline
  [@@deriving sexp_of, equal, enumerate]

  (** Bold for the title, the mode badge, the dirty and pending markers, and errors;
      every other style is plain. *)
  val default : Ches_screen.Style.t -> t list
end

(** The colors of [style] from {!Role}, and its font styles from [font] (default
    {!Font.default}). The font callback API is unchanged; document styles now match
    [Document { special; overlay; current_line; syntax }] rather than flat variants
    such as [Special_cursor_line] or [Search_match_current]. Interaction overlays
    replace foreground/background for contrast, without erasing underlying data. *)
val attrs
  :  ?font:(Ches_screen.Style.t -> Font.t list)
  -> Ches_screen.Style.t
  -> Attr.t list
