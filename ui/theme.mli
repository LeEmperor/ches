(** The one place colors and font styles are defined: a palette of semantic roles, the
    font styles of each {!Ches_screen.Style.t}, and the attributes they make. Several
    dark presets share one shape: a near-black ground, muted chrome, and color kept for
    the mode badge, the dirty marker, feedback, syntax, and escape forms. {!selected}
    picks the one drawn. Every label is also readable without color. *)

open! Core
open Bonsai_term

module Preset : sig
  type t =
    | Midnight (** Neutral gray ground, cool multi-hue syntax. *)
    | Crimson (** Faintly warm ground, red-based syntax. *)
    | Ember (** Warm earthy ground and syntax, gruvbox-like. *)
    | Glacier (** Blue-black ground, icy blue and teal syntax. *)
  [@@deriving sexp_of, equal, enumerate]
end

(** The preset ches draws with; a hardcoded choice, changed in theme.ml. *)
val selected : Preset.t

module Role : sig
  type t =
    | Backdrop
    (** Outside the tiles and under their frames: a shade darker, so tiles stand out. *)
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
    | Smear
    (** The animated cursor trail. Notty cannot query or set the terminal's native
        cursor color, so the trail matches the theme rather than that cursor. *)
    | Syntax_keyword
    | Syntax_string
    | Syntax_number
    | Syntax_comment
    | Syntax_type
    | Syntax_function
    | Syntax_module
    | Syntax_constant
  [@@deriving sexp_of, enumerate]

  (** The role's color in [preset] (default {!selected}). *)
  val color : ?preset:Preset.t -> t -> Attr.Color.t
end

(** Default syntax foreground role. Specials override it, and interaction overlays
    override both foreground and background. Padding remains Plain. *)
val syntax_role : Ches_screen.Style.Syntax.t -> Role.t

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
    replace foreground/background for contrast, without erasing underlying data.
    Frame cells (borders and their titles/hints) are on the backdrop. *)
val attrs
  :  ?font:(Ches_screen.Style.t -> Font.t list)
  -> Ches_screen.Style.t
  -> Attr.t list
