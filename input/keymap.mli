(** Modal key bindings: a state machine from {!Input.t} to actions: editor commands,
    and layout commands for the view.

    The keymap owns only the pending input (a count, and a Space leader waiting for
    its continuation). The editor's mode is passed in on every call, so the frontend
    reads it from [Editor.mode] after dispatching the previous commands.

    {2 Bindings}

    Normal-mode sequences come from {!Config.normal}, a validated {!Bindings.t}; the
    defaults are:

    {v
      Mode    Keys                   Command
      Normal  h / j / k / l          Move Left / Down / Up / Right
      Normal  w / b / e              Move (Word_forward / Word_backward / Word_end Small)
      Normal  W / B / E              Move (Word_forward / Word_backward / Word_end Big)
      Normal  0 / ^ / $              Move Line_start / First_nonblank / Line_end
      Normal  _ / g _                Move First_nonblank_down / Last_nonblank
      Normal  g g / G                Move First_line / Last_line
       Normal  %                      Move Matching_delimiter (no count)
       Normal  f/F/t/T + character    Find character forward/backward, on/before it
       Normal  ;/,                    Repeat last find / opposite direction
      Normal  i / a                  Enter_insert (Before_cursor / After_cursor)
      Normal  A / I                  Enter_insert (Line_end / First_nonblank)
      Normal  o / O                  Open_line_below / Open_line_above
        Normal  d{motion}, dd, D       Delete by motion / line / to line end
        Normal  y{motion}, yy           Yank by motion / line
        Normal  p / P                   Paste after / before; count repeats the register
       Normal  : e ! Enter             Force-reload the associated file
       Normal  x / X                  Delete character(s) under / before cursor
      Normal  v / V / Ctrl-v         Enter_visual (Characterwise / Linewise / Blockwise)
      Visual  v / V / Ctrl-v         Switch selection kind, keeping the anchor
      Visual  motions, counts        Move, extending the selection
      Visual  d / y / c              Visual_delete / Visual_yank / Visual_change
      Visual  I / A                  Visual_insert (block insert); a count repeats
      Visual  Escape                 Exit_visual
      Normal  u                      Undo
      Normal  Ctrl-r                 Redo
      Normal  Ctrl-e / Ctrl-y        View (Scroll Line_down / Line_up)
      Normal  Ctrl-d / Ctrl-u        View (Scroll Half_page_down / Half_page_up)
      Normal  z z / z t / z b        View (Scroll Cursor_middle / _top / _bottom), no count
      Normal  Space w                Save
      Normal  Space q                Quit
      Normal  Space Q                Force_quit
      Normal  Space v c              View Toggle_centered
      Normal  Space v h / l          View (Shift -2) / (Shift 2)
      Normal  Space v H / L          View (Shift -10) / (Shift 10)
      Normal  Space v -              View (Adjust_width -10)
      Normal  Space v + / =          View (Adjust_width 10)
      Normal  Space v n              View Toggle_absolute_numbers
      Normal  Space v N              View Toggle_relative_numbers
      Normal  Space v t              View Toggle_status
      Normal  Space v p h/l/k/j      View Position_status Left/Right/Above/Below
      Normal  Space v p - / + / =    View Adjust_status_size -2 / 2 / 2
      Normal  Space v z              View Toggle_zen
      Normal  Space v r              View Reset
      Normal  Space c c              View Open_palette
      Normal  Escape                 Cancel a pending count or sequence
      Both    Ctrl-c                 No command: cancel, and hint at Space q
      Insert  characters, Space      Insert_text (literal)
      Insert  Enter                  Insert_newline (autoindents)
      Insert  Tab                    Insert_soft_tab or Insert_text "\t" ({!Config.tab})
      Insert  Backspace, Ctrl-h      Delete_soft_tab_backward or Delete_backward
      Insert  Delete                 Delete_forward
      Insert  Escape                 Exit_insert
      Insert  j k                    Exit_insert ({!Config.insert_escape})
    v}

    {2 Counts}

    In Normal mode, digits typed before a sequence form a count: [1]–[9] start one,
    and any digit, including [0], extends it. A bare [0] is looked up as a binding
    instead ([Line_start] by default). A count of at most [Command.max_count]
    produces one counted command, e.g. [2 0 j] produces
    [Move { motion = Down; count = Some 20 }]; without a count, [count] is [None], so
    the editor can tell bare [G] from [1 G]. [x], [X], [p], and [P] accept a count.
    [d] and [y] keep their own count while waiting for a motion; operator and motion
    counts multiply (so [2d3w] deletes and [2y3w] yanks six words). While a count is pending, {!pending}
    shows it, followed by any keys of the sequence (["20"], ["20 g"], ["3 Space"]).

    A count is cancelled, with a {!notice} and without any command, when
    - it would exceed [Command.max_count];
    - the sequence it precedes is bound to a command that takes no count (every
      binding but [Move], and [Move] of a motion that does not [Motion.takes_count]),
      e.g. [3 x], [2 Space w], or [3 ^];
    - the next key does not continue a bound sequence, e.g. [3 z].
    Escape cancels it silently. Nothing typed before a cancellation carries over to
    the next input.

    {2 Insert-mode escape}

    The Insert-mode escape sequence (default [j k]) has no timeout and never hides
    typed text: [j] is inserted as soon as it is typed, and an immediately following
    [k] produces [Delete_backward; Exit_insert], removing the [j] before leaving
    Insert. Typing [j] then [k] literally therefore needs another route, such as a
    paste. Any other input in between, including a paste, ends the sequence.

    {2 Other input}

    Ctrl-c produces no command in either mode. It cancels any pending count or
    sequence, ends an Insert-mode escape sequence, and sets {!notice} to a hint about
    [Space q], so that a user who expects Ctrl-c to quit is not left stuck. (A
    terminal frontend in raw mode receives Ctrl-c as an ordinary key, not a signal.)

    [Space v] is the prefix for layout commands ({!View_command.t}), which the frontend
    applies to its own view state; every other binding is an editor command.

    In Visual mode, a pending sequence (such as [f] waiting for its character, or
    the [g] of [g g]) takes the next key, so [v f d] finds a [d] rather than
    deleting.

    Other keys are ignored. In Normal mode, a key that does not continue a pending
    count or sequence cancels it without producing commands, and sets {!notice}. A
    pending leader has no timeout.

    Pasted text becomes one literal [Insert_text] in Insert mode. In Normal mode it
    is ignored (cancelling any pending count or sequence) with a {!notice}; it is
    never interpreted as Normal-mode keys. *)

(* [open! Core] would shadow our [Command] with Core's command-line [Command]. *)
module Editor_command := Ches_core.Command

open! Core
module Command := Editor_command

module Input : sig
  (** {2 Adapter contract for paste}

      A frontend delivers a paste as a single [Paste] holding the exact pasted text,
      not as the key presses that make it up. With a terminal that brackets pastes
      (Bonsai_term reports [Paste `Start], key presses, [Paste `End]), the adapter
      collects the bracketed keys into a string, e.g. with {!Key.text}, and sends one
      [Paste] at the end. The text is not normalized: CR bytes and other invalid text
      are passed through and rejected by the editor, which reports an error. *)
  type t =
    | Key of Key.t
    | Paste of string
  [@@deriving sexp_of]
end

module Config : sig
  type tab =
    | Literal_tab (** Tab inserts a TAB character; Backspace deletes one code point. *)
    | Spaces of int
    (** Soft tabs of this width, at least 1: Tab inserts spaces to the next multiple
        of the width, and Backspace deletes spaces back to the previous one. *)
  [@@deriving sexp_of]

  type t =
    { tab : tab
    ; insert_escape : (char * char) option
    (** Two printable ASCII characters that leave Insert mode when typed in a row,
        or [None] for Escape only. *)
    ; normal : Bindings.t (** Normal-mode key sequences. *)
    }
  [@@deriving sexp_of]

  (** [Spaces 2], [Some ('j', 'k')], and [Bindings.default]. *)
  val default : t
end

module Action : sig
  (** What a key sequence asks for. [sexp_of] prints an editor command untagged, as
      plain [Command.t], and a view command as [(View ...)]. *)
  type t =
    | Editor of Command.t
    | View of View_command.t
  [@@deriving sexp_of, equal]
end

type t [@@deriving sexp_of]

(** A keymap with no pending sequence. Raises if [config.tab] is [Spaces n] with
    [n < 1]. *)
val create : Config.t -> t

(** Clear all pending input while retaining configured bindings. *)
val reset : t -> t

(** Look up configured Normal bindings without feeding editor input. Used for
    workspace-only routing while a companion pane owns input. *)
val lookup : t -> Key.t list -> Bindings.lookup

(** The configured Normal bindings ({!Config.t.normal}). *)
val bindings : t -> Bindings.t
val config : t -> Config.t

(** [feed t ~mode input] interprets [input] in [mode] and returns the actions to
    perform, in order. *)
val feed : t -> mode:Ches_core.Mode.t -> Input.t -> t * Action.t list

(** The count and keys of an incomplete sequence, for the status line, e.g.
    ["Space"] or ["20"]. *)
val pending : t -> string option

(** The in-progress [/]/[?] query, for highlight-only incremental search.  It is
    [None] outside a search prompt and does not move the editor cursor. *)
val search_preview : t -> string option

(** Feedback about the most recent {!feed}, e.g. ["Space z is not bound"]. Cleared
    by the next {!feed}. Independent of the editor's own message. *)
val notice : t -> string option
