(** Adapts Bonsai_term events to {!Ches_screen.Ui_state.Input.t}, following the
    adapter contract in [Ches_input.Key].

    - Characters become [Char]; Shift is already folded into them by the terminal.
    - Ctrl plus a letter becomes [Ctrl] of the lowercase letter. Ctrl-H, which some
      terminals send for Backspace, is [Ctrl 'h'].
    - Enter, Tab, Backspace, Delete, Escape and unmodified Left/Right/Home/End
      map to themselves. Notty's Ctrl-M (physical Enter with CR-to-LF translation
      disabled) also maps to Enter. Navigation never contributes paste text.
    - Tab with Shift becomes [Shift_tab] for previous-result navigation.
    - A terminal sends Alt-x as Escape followed by x, and an Escape typed quickly
      before another key arrives the same way, so a Meta key becomes [Escape] and then
      the key without Meta. Dropping it would lose the Escape.
    - Bracketed paste markers become [Paste_start] and [Paste_end].
    - Everything else (Up/Down, modified navigation, function keys, mouse events,
      other Ctrl combinations) is dropped. *)

open! Core
open Bonsai_term

(** With [terminal=true], every key and modifier is preserved as [Terminal_key],
    including control punctuation, navigation, function keys and Meta (Alt).
    Notty's [Enter] denotes LF and is forwarded as Ctrl-J, distinct from the
    physical Enter key's Ctrl-M (CR). The CLI disables CR/LF input translation.
    Paste boundaries are unchanged in either mode. *)
val inputs : ?terminal:bool -> Event.t -> Ches_screen.Ui_state.Input.t list
