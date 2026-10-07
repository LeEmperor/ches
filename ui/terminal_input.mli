(** Adapts Bonsai_term events to {!Ches_screen.Ui_state.Input.t}, following the
    adapter contract in [Ches_input.Key].

    - Characters become [Char]; Shift is already folded into them by the terminal.
    - Ctrl plus a letter becomes [Ctrl] of the lowercase letter. Ctrl-H, which some
      terminals send for Backspace, is [Backspace].
    - Enter, Tab, Backspace, Delete, and Escape map to themselves.
    - Tab with Shift becomes [Shift_tab] for previous-result navigation.
    - A terminal sends Alt-x as Escape followed by x, and an Escape typed quickly
      before another key arrives the same way, so a Meta key becomes [Escape] and then
      the key without Meta. Dropping it would lose the Escape.
    - Bracketed paste markers become [Paste_start] and [Paste_end].
    - Everything else (arrows, function keys, mouse events, other Ctrl combinations)
      is dropped. *)

open! Core
open Bonsai_term

val inputs : Event.t -> Ches_screen.Ui_state.Input.t list
