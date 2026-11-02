open! Core

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

let no_modifiers : modifiers = { shift = false; alt = false; ctrl = false }
