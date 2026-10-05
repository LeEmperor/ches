(** All UI-side state, and the transition for one input. No Bonsai types appear here, so
    tests drive it headlessly, exactly as the terminal frontend does.

    The model holds the {!Ches_app.Controller.t} (editor and keymap), the layout
    preferences, the scroll position, a bracketed paste being collected, and the shared
    controller feedback. Workspace requests and zen suppression are UI state, not editor
    state. Problems has read-only keyboard capture; status remains non-focusable. *)

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
    | Animation_tick of Time_ns.t
     (** A timestamped frontend animation-clock pulse; never reaches the editor. *)
    | Resize (** Reconcile allocation/focus without interpreting editor input. *)
  [@@deriving sexp_of]
end

type t

val create
  :  ?prefs:Geometry.Prefs.t
  -> ?workspace_prefs:Workspace.Prefs.t
  -> ?smear_enabled:bool
  -> Ches_app.Controller.t
  -> t

val controller : t -> Ches_app.Controller.t
val prefs : t -> Geometry.Prefs.t
val workspace_prefs : t -> Workspace.Prefs.t
val zen : t -> bool
val problems_visible : t -> bool
val problems_current_document : t -> bool
val problems_focused : t -> width:int -> height:int -> bool
val problem_navigation : t -> width:int -> height:int -> Problem_navigation.t
val selected_problem : t -> width:int -> height:int -> Ches_error.Error.Problem.t option
val problem_details : t -> bool
val problem_detail_top : t -> int
val problem_notice : t -> string option
val problem_pending : t -> string option

(** Shared feedback update with selection reconciliation. No editor input or IO. *)
val update_feedback
  : t -> width:int -> height:int -> Ches_error.Error.update -> t

(** Effective workspace allocation. Zen suppresses status without changing requested
    visibility/placement/sizes. Width and height requests are remembered separately.
    Status remains non-focusable. Problems focus is effective only while its
    allocation exists. Resize events persistently restore document focus when hidden. *)
val workspace : t -> width:int -> height:int -> Workspace.t

val scroll : t -> Scroll.t
val message : t -> Message.t option
val animation : t -> Animation.t

(** Whether a bracketed paste is being collected. *)
val pasting : t -> bool

(** [Ches_app.Controller.take_clipboard] on the model's controller: what the frontend
    should put on the system clipboard after the inputs it just applied. *)
val take_clipboard : t -> t * string option

(** Whether an input has returned [Exit]. From then on, {!apply} ignores its input and
    returns [Exit] again, so keys that arrive before the frontend has shut down (say,
    [Space w] typed right after [Space Q]) never run. *)
val exited : t -> bool

(** The visible cursor's terminal-cell coordinate, after applying layout and scroll.
    During a block insert it is at the first of [Editor.block_insert_points], which can be
    inside a TAB or past the line's end before anything is typed; the scroll keeps that
    cell in view. {!Frame} then hides the terminal cursor and draws every point as a
    styled cell instead; this position still drives the smear. *)
val cursor_position : t -> width:int -> height:int -> (int * int) option

(** Applies one input on a [width] x [height] screen.

    Keys between [Paste_start] and [Paste_end] are collected with [Key.text] and delivered
    as one paste at the end; keys without text are dropped. Document input goes to the
    controller, with its effects (such as saving) performed before this returns. View
    commands the controller returns update {!prefs} (see {!apply_view}) or, for [Scroll],
    the scroll.

    {2 Problems pane capture}

    Normal [Space v o] shows/focuses problems, or returns to the editor. Entry and
    return cancel pending editor input. Existing Normal prefixes/counts/search retain
    keymap precedence; focus does not intercept an incomplete editor command.
    In problems, [j/k], [gg/G], [Ctrl-d/u] select/scroll; [e] toggles wrapped details
    (movement then scrolls details), [a] acknowledges the selected identity without
    resolving it, and Enter performs a validated current-file jump and returns.
    Escape cancels a pane prefix, then closes details, then returns without
    acknowledgement. Tab returns directly. [Space v] uses configured view bindings;
    editor commands and document scrolling are rejected during capture.
    Hiding/zen/undersized allocations restore document focus and clear pane prefixes.
    Bracketed paste retains its start owner; pane paste is rejected even after resize.
    Selection follows identity; removal/filtering chooses the previous index's next
    neighbor, falling back to the last item. An empty list retains pane focus until
    explicitly returned/hidden. No terminal cursor or editor smear is drawn in capture.

    {2 Scrolling}

    Scroll commands work on the text viewport's rows and change nothing when it has none.
    The first visible line stays within the document, so [Line_down] ([Ctrl-e]) can scroll
    until the last line is at the top. When a scroll would take the cursor line out of
    view, the cursor is moved to the nearest visible line with a counted [Up]/[Down]
    through {!Ches_app.Controller.move}, keeping its preferred column. This is the one
    view command that touches the editor: it moves the cursor only, never text, history,
    or dirty state.

    - [Line_down]/[Line_up] scroll by one line or the count.
    - [Half_page_down]/[Half_page_up] scroll and move the cursor by half the rows (at
      least 1), or the count. Scrolling down stops once the last line is at the bottom (or
      stays, if scrolled further already); the cursor still moves, so a repeat reaches the
      last line. At the top, only the cursor moves.
    - [Cursor_top]/[Cursor_middle]/[Cursor_bottom] put the cursor line at the top, middle
      (row [(rows - 1) / 2]), or bottom, without moving the cursor; the first line is not
      lowered below the document start.

    {2 Messages}

    Status presentations query the controller's shared feedback. A dispatched editor
    command clears transient feedback; prefixes, ignored input, animation, and layout
    actions do not. Layout feedback and keymap notices post new transient notifications.
    Active save/reload problems remain until matching recovery. Idle Normal Escape
    acknowledges the currently presented problem; cancellation and mode exits take
    precedence. [Space v e] cycles retained details without retrying or renewing
    attention. Acknowledged problems remain visible as a compact count until recovery.

    Status commands in zen update saved requests without leaving zen. Document reset
    leaves workspace intent alone.

    The scroll is then fitted to keep the cursor visible (see {!fitted_scroll}). Once an
    input returns [Exit], no later input is applied (see {!exited}). *)
val apply : t -> width:int -> height:int -> Input.t -> t * Ches_app.Controller.Status.t

(** The requested preferences after a view command; [Scroll] leaves them unchanged.
    [Shift] and [Adjust_width] also select centered mode, so their effect is visible. The
    requested width is kept within {!min_width}..{!max_width} and the offset within
    [-max_offset..max_offset]; the screen may show less (see {!Geometry.compute}), and the
    request is kept for when it grows. *)
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

(** Document geometry within the effective workspace on a [width] x [height] screen. *)
val geometry : t -> width:int -> height:int -> Geometry.t

(** {!scroll} fitted to a [width] x [height] screen, so a resize keeps the cursor visible
    before the next input arrives. The fit fills the viewport (lowering the first line so
    it is not partly empty while earlier lines are hidden) only when the number of text
    rows differs from the last applied input's, that is, after a resize; otherwise a view
    scrolled past the end stays put (see {!Scroll.fit}). *)
val fitted_scroll : t -> width:int -> height:int -> Scroll.t

(** Explicit-allocation counterparts of the workspace queries above. All three use the
    same allocation and explicit status policy; scroll positions remain document
    coordinates and cursor positions are terminal coordinates. These queries do not change
    the model or editor. *)
val geometry_in : t -> allocation:Geometry.Rect.t -> reserve_status_row:bool -> Geometry.t

val fitted_scroll_in
  :  t
  -> allocation:Geometry.Rect.t
  -> reserve_status_row:bool
  -> Scroll.t

val cursor_position_in
  :  t
  -> allocation:Geometry.Rect.t
  -> reserve_status_row:bool
  -> (int * int) option
