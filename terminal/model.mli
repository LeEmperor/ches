open! Core

(** UI-independent terminal protocol. Coordinates are zero based. Snapshots own
    their arrays and remain valid after subsequent terminal activity. *)
type color = Default | Indexed of int | Rgb of int * int * int
[@@deriving sexp, equal]

type style =
  { fg : color
  ; bg : color
  ; bold : bool
  ; italic : bool
  ; underline : bool
  ; reverse : bool
  }
[@@deriving sexp, equal]

(** Empty cells contain a space and have width 1. A wide glyph's continuation
    cell has empty text and width 0; its leading cell has width 2. Combining
    characters belong to the leading cell's UTF-8 [text]. *)
type cell = { text : string; width : int; style : style }
[@@deriving sexp, equal]

type snapshot =
  { rows : cell array array
  ; cursor_row : int
  ; cursor_col : int
  ; cursor_visible : bool
  ; exited : string option
  }
[@@deriving sexp, equal]

type modifiers = { shift : bool; alt : bool; ctrl : bool }
[@@deriving sexp, equal]

(** [Char] is the actual Unicode character (already case/shift translated by
    the frontend). [Function] supports F1..F35; F13..F24 and F25..F35 use the
    standard xterm shift/control aliases of F1..F12. *)
type key_code =
  | Char of Uchar.t
  | Enter | Tab | Backspace | Escape
  | Up | Down | Left | Right | Home | End | Page_up | Page_down
  | Insert | Delete | Function of int
[@@deriving sexp, equal]

type key = { code : key_code; modifiers : modifiers }
[@@deriving sexp, equal]

type request =
  | Start of { cwd : string; rows : int; cols : int }
  | Key of key
  | Paste of string
  | Resize of { rows : int; cols : int }
  | Stop
[@@deriving sexp, equal]

type event = Snapshot of snapshot | Failed of string
[@@deriving sexp, equal]

val no_modifiers : modifiers
