(** All UI-side state, and the transition for one input. No Bonsai types appear here,
    so tests drive it headlessly, exactly as the terminal frontend does.

    The model holds the {!Ches_app.Controller.t} (editor and keymap), the layout
    preferences, the scroll position, a bracketed paste being collected, and the
    status line's message slot. *)

open! Core
open Ches_input

module Message : sig
  type kind =
    | Info
    | Warning (** Keymap notices. *)
    | Error
  [@@deriving sexp_of, equal]

  type t =
    { kind : kind
    ; text : string
    }
  [@@deriving sexp_of, equal]
end

(** Normalized terminal events. The frontend converts what its terminal reports. *)
module Input : sig
  type t =
    | Key of Key.t
    | Paste_start
    | Paste_end
  [@@deriving sexp_of]
end

type t

val create : ?prefs:Geometry.Prefs.t -> Ches_app.Controller.t -> t
val controller : t -> Ches_app.Controller.t
val prefs : t -> Geometry.Prefs.t
val scroll : t -> Scroll.t
val message : t -> Message.t option

(** Whether a bracketed paste is being collected. *)
val pasting : t -> bool

(** Whether an input has returned [Exit]. From then on, {!apply} ignores its input and
    returns [Exit] again, so keys that arrive before the frontend has shut down (say,
    [Space w] typed right after [Space Q]) never run. *)
val exited : t -> bool

(** Applies one input on a [width] x [height] screen.

    Keys between [Paste_start] and [Paste_end] are collected with [Key.text] and
    delivered as one paste at the end; keys without text are dropped. Everything else
    goes to the controller, with its effects (such as saving) performed before this
    returns. View commands the controller returns update {!prefs} (see
    {!apply_view}) or, for [Scroll], the scroll.

    {2 Scrolling}

    Scroll commands work on the text viewport's rows and change nothing when it has
    none. The first visible line stays within the document, so [Line_down]
    ([Ctrl-e]) can scroll until the last line is at the top. When a scroll would take
    the cursor line out of view, the cursor is moved to the nearest visible line with
    a counted [Up]/[Down] through {!Ches_app.Controller.move}, keeping its preferred
    column. This is the one view command that touches the editor: it moves the
    cursor only, never text, history, or dirty state.

    - [Line_down]/[Line_up] scroll by one line or the count.
    - [Half_page_down]/[Half_page_up] scroll and move the cursor by half the rows (at
      least 1), or the count. Scrolling down stops once the last line is at the
      bottom (or stays, if scrolled further already); the cursor still moves, so a
      repeat reaches the last line. At the top, only the cursor moves.
    - [Cursor_top]/[Cursor_middle]/[Cursor_bottom] put the cursor line at the top,
      middle (row [(rows - 1) / 2]), or bottom, without moving the cursor; the first
      line is not lowered below the document start.

    {2 Messages}

    The message slot shows the feedback of the most recent input that produced any:
    the keymap's notice if it set one; otherwise layout feedback if the input produced
    a view command, such as [Width 110 (76 fit)] (the requested value, then the
    effective one on this screen when it differs) or [Line numbers: hybrid (no room)]
    (the requested style, noting when the screen is too small for the gutter);
    otherwise the editor's message if the input dispatched an editor command (which
    may clear the slot). Other inputs, such as scrolling or the first key of a
    sequence, leave it unchanged.

    The scroll is then fitted to keep the cursor visible (see {!fitted_scroll}). Once an input returns
    [Exit], no later input is applied (see {!exited}). *)
val apply
  :  t
  -> width:int
  -> height:int
  -> Input.t
  -> t * Ches_app.Controller.Status.t

(** The requested preferences after a view command; [Scroll] leaves them unchanged.
    [Shift] and [Adjust_width] also
    select centered mode, so their effect is visible. The requested width is kept
    within {!min_width}..{!max_width} and the offset within
    [-max_offset..max_offset]; the screen may show less (see {!Geometry.compute}),
    and the request is kept for when it grows. *)
val apply_view : Geometry.Prefs.t -> View_command.t -> Geometry.Prefs.t

val min_width : int
val max_width : int
val max_offset : int

(** [apply] for each input in order, stopping at [Exit]. *)
val apply_all
  :  t
  -> width:int
  -> height:int
  -> Input.t list
  -> t * Ches_app.Controller.Status.t

(** The geometry of a [width] x [height] screen for this state. *)
val geometry : t -> width:int -> height:int -> Geometry.t

(** {!scroll} fitted to a [width] x [height] screen, so a resize keeps the cursor
    visible before the next input arrives. The fit fills the viewport (lowering the
    first line so it is not partly empty while earlier lines are hidden) only when the
    number of text rows differs from the last applied input's, that is, after a
    resize; otherwise a view scrolled past the end stays put (see {!Scroll.fit}). *)
val fitted_scroll : t -> width:int -> height:int -> Scroll.t
