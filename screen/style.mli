(** What each part of the screen is, for the frontend's theme to color. The theme maps
    every case to attributes in one place. *)

open! Core

module Syntax : sig
  (** Placeholder for phase 2's provider-independent categories. Plain retains the
      existing foreground; phase 1 introduces no syntax colors. *)
  type t = Plain [@@deriving sexp_of, equal]
end

module Overlay : sig
  type t =
    | Search_match
    | Search_current
    | Selection
    | Insert_cursor
    (** The block insert's own software cursor. *)
    | Insert_point
    (** A block insert's copied insertion point on another line. *)
  [@@deriving sexp_of, equal, enumerate]
end

module Document : sig
  type t =
    { syntax : Syntax.t
    ; current_line : bool
    ; special : bool (** Control escapes and clipped-glyph markers. *)
    ; overlay : Overlay.t option
    }
  [@@deriving sexp_of, equal]

  val create
    :  ?syntax:Syntax.t
    -> ?current_line:bool
    -> ?special:bool
    -> ?overlay:Overlay.t
    -> unit
    -> t
end

(** How tile chrome sits on the screen, for the theme. [Classic] draws frames on the
    tile background; [Open] draws frame cells (borders and the labels in them) on the
    backdrop, so rounded corners read as round, and marks the gaps between
    side-by-side tiles with {!Separator}. *)
module Chrome : sig
  type t =
    | Classic
    | Open
  [@@deriving sexp_of, equal]
end

type t =
  | Backdrop (** The screen outside the tile and status line. *)
  | Document of Document.t
  (** Independent foreground, current-line background, special-display treatment,
      and interaction overlay. Chrome styles remain separate. *)
  | Gutter
  | Gutter_cursor_line
  | Border
  | Border_focused (** The frame of the focused supporting tile. *)
  | Title (** Text set into the top border, such as the filename. *)
  | Title_special (** Escape forms and cut markers there. *)
  | Status (** The status line's background and plain fields. *)
  | Status_special (** Escape forms in the filename and messages. *)
  | Hint (** Secondary text set into a frame, such as key hints. *)
  | Separator (** A gap between side-by-side tiles, in [Open] chrome. *)
  | Mode of Ches_core.Mode.t (** The mode badge. *)
  | Dirty
  | Pending
  | Info
  | Warning
  | Error
  | Smear (** The foreground-only animated cursor overlay. *)
[@@deriving sexp_of, equal]

val document
  :  ?syntax:Syntax.t
  -> ?current_line:bool
  -> ?special:bool
  -> ?overlay:Overlay.t
  -> unit
  -> t

(** Replaces only the overlay, retaining all underlying document components.
    Raises [Invalid_argument] for chrome styles. The caller resolves interaction
    precedence: insert cursor/point > selection > current/ordinary search. *)
val with_overlay : t -> Overlay.t -> t

(** Compact effective-appearance labels for frame dumps. Unlike [sexp_of_t], these
    omit document components hidden by an overlay. *)
val to_string_hum : t -> string
