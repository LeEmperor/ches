(** The shared shell of a supporting tile: its rounded frame, the title and footer set
    into that frame, inset padding, focus decoration, and the deterministic way all of
    these degrade in a small allocation. Content adapters supply only a title, an
    optional footer, and body rows sized to {!Layout.content}; none draws its own frame
    or padding. One {!Layout.t} drives rendering, the adapter's viewport (rows to
    scroll by, width to wrap at), and any future text cursor, so they always agree.

    Like {!Tile_text}, this knows nothing about problems, feedback, or any source. *)

open! Core

(** Per-consumer defaults. *)
module Policy : sig
  type t =
    { padding : int (** Blank cells inside each side border; no vertical padding. *)
    ; min_content_width : int
    ; min_content_height : int
    (** The frame is drawn only when it leaves at least this content. *)
    ; bare_labels : bool
    (** Without a frame, give the title and footer rows of their own; otherwise
        show only the body. *)
    }
  [@@deriving sexp_of, equal]

  (** Minor views: padding 1, at least 12 by 1 content cells, labelled rows when
      bare. A minor allocation ({!Workspace.min_minor_width} by 3) is always framed. *)
  val minor : t

  (** Dedicated status: padding 1, at least 8 by 5 content cells (the full vertical
      field order), and no title or footer rows when bare, so a shallow or narrow
      status cell keeps every row for its essential fields. *)
  val status : t
end

module Layout : sig
  type t =
    { outer : Geometry.Rect.t (** The allocation, with negative sizes made zero. *)
    ; framed : bool
    ; padding : int (** Effective horizontal padding; 0 when bare or squeezed. *)
    ; title : Geometry.Rect.t
    (** The top border between its corners, or the first row when bare with labels;
        zero height otherwise. *)
    ; footer : Geometry.Rect.t (** Likewise the bottom border or last row. *)
    ; content : Geometry.Rect.t (** Body rows, in terminal coordinates. *)
    }
  [@@deriving sexp_of, equal]
end

(** The layout of [rect] under [policy]. In order of preference: a rounded frame with
    padding, a frame without padding, then bare (no frame). Every rectangle lies within
    the normalized allocation; origins are preserved. *)
val layout : Policy.t -> Geometry.Rect.t -> Layout.t

(** A footer or other label: its text and style. *)
module Label : sig
  type t =
    { text : string
    ; style : Style.t
    }
  [@@deriving sexp_of]

  (** Muted key hints. *)
  val hint : string -> t

  (** A capture notice (warning), else a pending prefix, else [default] as a hint. *)
  val footer : notice:string option -> pending:string option -> default:string -> t
end

module Content : sig
  type t =
    { title : string
    ; footer : Label.t option
    ; body : Span.t list list
    (** Rows of at most [content.width] cells; missing rows are blank, extra rows and
        cells are cut. *)
    }
end

(** Exactly [outer.height] rows of exactly [outer.width] cells. A framed title or
    footer is set into its border as [─ text ─], cut with [>] when it does not fit, and
    the border is unbroken when there is no room for any text. The focused view's frame
    is drawn in {!Style.Border_focused}. Padding and blank rows use the content
    background ({!Style.Status}); content styles are kept. *)
val render : Layout.t -> focused:bool -> Content.t -> Span.t list list
