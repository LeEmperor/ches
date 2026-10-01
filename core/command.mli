(** Editor actions, independent of the keys that trigger them. {!Editor.dispatch}
    documents which commands apply in which mode. *)

open! Core

module Direction : sig
  type t =
    | Left
    | Right
    | Up
    | Down
  [@@deriving sexp_of, equal, enumerate]
end

type t =
  | Move of Direction.t
  | Enter_insert
  | Exit_insert
  | Insert_text of string (** Literal text, including LF for a new line. *)
  | Delete_backward (** Remove the code point before the cursor. *)
  | Delete_forward (** Remove the code point after the cursor. *)
  | Insert_soft_tab of int
  (** Insert spaces up to the next column that is a multiple of the width. *)
  | Delete_soft_tab_backward of int
  (** Remove the spaces before the cursor back to the previous column that is a
      multiple of the width, stopping at anything other than a space. Without a space
      before the cursor, the same as [Delete_backward]. *)
  | Delete_char (** Remove the code point under the Normal-mode cursor. *)
  | Undo
  | Redo
  | Save
  | Quit (** Exit unless there are unsaved changes. *)
  | Force_quit (** Exit, discarding unsaved changes. *)
[@@deriving sexp_of, equal]
