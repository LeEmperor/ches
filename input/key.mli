(** Terminal-independent key presses.

    {2 Adapter contract}

    A frontend converts its native key events into [t] before they reach {!Keymap}:

    - A key that produces a character, including Space, is [Char] of that code point.
      Shift is folded into the character: Shift-q is [Char 'Q'], with no separate
      modifier.
    - [Char] is never a control character (U+0000–U+001F, U+007F–U+009F). Keys that
      would produce one are [Enter], [Tab], [Backspace], [Escape], or [Ctrl].
     - Ctrl plus an ASCII letter is [Ctrl] of the {i lowercase} letter, whether or not
       Shift was held: Ctrl-R is [Ctrl 'r'].
     - Shift-Tab is [Shift_tab], distinct from the text-producing [Tab].
    - Keys with no constructor here (arrows, function keys, Meta combinations, ...)
      are dropped by the adapter. They therefore neither run commands nor cancel a
      pending sequence.

    Pasted text is not a sequence of keys; see {!Keymap.Input}. *)

open! Core

type t =
  | Char of Uchar.t
  | Ctrl of char
  | Enter
  | Tab
  | Shift_tab (** Shift-Tab, distinct from text-producing Tab. *)
  | Backspace
  | Delete
  | Escape
[@@deriving sexp_of, equal]

(** [char c] is [Char] of the ASCII character [c]. *)
val char : char -> t

(** The value of an ASCII digit key [Char '0'] to [Char '9']. *)
val digit : t -> int option

(** For messages, e.g. ["x"], ["Space"], ["Ctrl-r"], ["Escape"]. *)
val to_string_hum : t -> string

(** The text a key inserts in Insert mode: the UTF-8 encoding of a [Char], ["\n"]
    for [Enter], ["\t"] for [Tab]. [None] for other keys and for a [Char] that
    violates the contract by being a control character. A frontend collecting
    bracketed-paste key events into a paste string can use this too. *)
val text : t -> string option
