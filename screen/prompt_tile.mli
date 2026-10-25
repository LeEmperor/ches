(** The single-line prompt float: a registered view's request for a line of text
    ({!View_registry.Ask.Prompt}), such as a branch name, opened on the single float
    slot over that view, which is neither left nor changed meanwhile. Its input edits
    like the palette's query ({!Ches_palette.Query}: typed and pasted text is
    sanitized to one line). The view's validation runs on every edit once the text
    has been edited, or when Enter is refused; its error shows on the row under the
    input. Enter accepts valid text; Escape, Tab and Ctrl-c cancel ({!Ui_state} routes
    them). Either closes it and returns focus to the view. *)

open! Core
open Ches_input

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t

type t [@@deriving sexp_of]

(** [validate] gives [Some error] for text that cannot be accepted. *)
val create
  :  origin:Ches_tile.View_id.t
  -> title:string
  -> initial:string
  -> validate:(string -> string option)
  -> t

(** The view that asked, and that focus returns to. *)
val origin : t -> Ches_tile.View_id.t

val title : t -> string
val text : t -> string

(** The validation error on display, if any. *)
val error : t -> string option

val preferred_size : Floating.Size.t

(** The smallest outer size: a frame, the input and the error row. *)
val minimum : Floating.Size.t

module Event : sig
  type t =
    | Insert of Uchar.t
    | Paste of string
    | Backspace
    | Delete_word
  [@@deriving sexp_of]
end

type action =
  | Edit of Event.t
  | Accept
[@@deriving sexp_of]

(** Characters, including Space, [?] and [q], are text; Backspace deletes a
    character, and Ctrl-w or Ctrl-h a word; Enter accepts. *)
val interpret : Key.t list -> action Ches_tile.Content_key.t

val hint : string
val update : t -> Event.t -> t

(** The text when it passes validation; otherwise the prompt with the error shown. *)
val accept : t -> (string, t) Result.t

(** The text-entry point after the input, in a [width]-cell content area. *)
val cursor : t -> width:int -> Ches_tile.Cursor.t

(** Shell content for a [width] by [rows] content viewport. Control hints default to
    hidden; notices remain visible. *)
val render : ?hotkey_hints:bool -> ?notice:string -> t -> width:int -> rows:int -> Tile_shell.Content.t
