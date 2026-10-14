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

module Floating_layer : sig
  (** Adapter-independent opaque shell. [cursor] is relative to [layout.content];
      it is drawn only when [id] is the host's cursor owner. *)
  type t =
    { id : Ches_tile.View_id.t
    ; layout : Tile_shell.Layout.t
    ; content : Tile_shell.Content.t
    ; cursor : Ches_tile.Cursor.t option
    }
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

(** Compose the effective workspace's document, optional status tile, and minor views
    (each in the shared {!Tile_shell}, its content from its adapter) against a
    screen-sized backdrop. Only the cursor owner draws a terminal cursor: the document
    (with its smear) when focused, or a focused minor view in the shape it asks for (see
    {!Ui_state.minor_cursor}). Scrolling and cursor placement share its document geometry.
    Compact/zen layouts retain bottom-row feedback. An explicit [allocation] instead
    renders only the document there, clipped to screen bounds, reserving a status row
     by default. [reserve_status_row] overrides either policy for headless callers.

     The live palette renders as one opaque shell over the complete tiled frame;
     [floating] can supply an explicit adapter-independent shell instead, clipping
     it to the screen without reallocating the workspace. Its supplied layout
     drives shell rendering, host availability, and content-relative cursor placement.
     Only the host's cursor owner supplies a cursor; floating capture suppresses
     document smear. Covered document cursor/smear cells are never drawn above it.

    The document uses the controller's cached current highlights by default, with no
    parsing. [highlights] overrides them with an expected current key and snapshot. The
    caller owns identity/configuration and must supply the current key, never the key
    copied from an obsolete result. Mismatched keys or editor revisions fall back to
    plain text. No provider work occurs here. *)
val render
  :  ?highlights:Ches_highlight.Snapshot.Key.t * Ches_highlight.Snapshot.t
  -> ?allocation:Geometry.Rect.t
   -> ?reserve_status_row:bool
   -> ?floating:Floating_layer.t
  -> Ui_state.t
  -> width:int
  -> height:int
  -> t

(** Explicit workspace cache. Animation and file work with unchanged explicit
     visual stamps can retain rows/base through [apply_inputs]. All other actions,
     including empty synchronization turns, invalidate. Dimensions and file content
     stamps are checked independently; mutable picker equality is never a cache key. [draw_base] is
    called once per miss, allowing the frontend to retain its base terminal image.
    Hits only rasterize smear and select the already computed settled cursor. *)
module Cache : sig
  type frame = t
  type 'a t
  val create : unit -> 'a t
  val invalidate : 'a t -> unit
  (** Shared production transition boundary: only already-sized animation/pure file
      work may retain rows/base, after explicit session/content/preview stamps match.
      All other inputs invalidate. Effects/after_step still run on work turns. *)
  val apply_inputs : ?after_step:(Ui_state.t -> Ui_state.t) -> 'a t -> Ui_state.t
    -> width:int -> height:int -> Ui_state.Input.t list -> Ui_state.t * Ches_app.Controller.Status.t
  val get : 'a t -> Ui_state.t -> width:int -> height:int
    -> draw_base:(frame -> 'a) -> frame * 'a
end

(** The screen as text, one line per row, each ending in [|] to show the width, then
    the cursor. For tests. *)
val to_string : t -> string

(** Each row's spans with their styles. For tests. *)
val to_string_styled : t -> string
