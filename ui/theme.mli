(** Terminal mapping of the shared immutable theme library. The same palette applies
    to Workspace, Zen, and Bare presentations. Every label is readable without color. *)

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

(** Legacy default preset (Crimson). Rendering defaults to
    [Ches_theme.Theme.default] instead. *)
val selected : Preset.t

module Role : sig
  include module type of Ches_theme.Theme.Role
    with type t = Ches_theme.Theme.Role.t

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

(** Colors from [theme] (default [Ches_theme.Theme.default]) and fonts from
    [font] (default {!Font.default}). Overlays replace foreground/background;
    frames sit on the backdrop. No global state is changed. *)
val attrs
  :  ?theme:Ches_theme.Theme.t
  -> ?font:(Ches_screen.Style.t -> Font.t list)
  -> Ches_screen.Style.t
  -> Attr.t list
