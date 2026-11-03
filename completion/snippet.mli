open! Core
open Ches_core

type range = { start : int; stop : int } [@@deriving sexp_of, equal, compare]
type field = { number : int; ranges : range list } [@@deriving sexp_of, equal, compare]
type t [@@deriving sexp_of, equal]

(** UTF-8 byte offsets, relative to expanded text. Numbered fields are sorted;
    zero is the final cursor, implicitly at the end when absent. Defaults on a
    later occurrence also populate earlier mirrors. Nested defaults
    and transforms are rejected. Supported filename variables remain resolvable
    after parsing; choices use their first option as the default. *)
val parse : string -> t Or_error.t
(** Resolve TM_FILENAME, TM_FILENAME_BASE, TM_DIRECTORY and TM_FILEPATH against
    a lexical editor path, with no I/O. None/empty paths use literal defaults or
    empty text. [parse] retains unresolved variables and initially uses defaults;
    [resolve] may be called again for another path. Unknown variables are errors
    at parse time. No recursive defaults or transforms. *)
val resolve : t -> path:string option -> t Or_error.t
val text : t -> string
val fields : t -> field list
val final_cursor : t -> int

(** Add [prefix] after every expanded newline, including newlines introduced by
    linked defaults. Retains variables, choices and accurate ranges. *)
val indent : t -> prefix:string -> t Or_error.t

module Session : sig
  type template = t
  type t [@@deriving sexp_of]
  type direction = Next | Previous [@@deriving sexp_of, equal]
  type change

  (** Validate that the expansion is installed at [base] in this snapshot.
      Starts with the first field's first occurrence selected. With no fields,
      starts finished at the final cursor. *)
  val start : template -> base:int -> revision:int -> text:Text_buffer.t -> t Or_error.t
  val fields : t -> field list
  val active : t -> field option
  (** The occurrence containing the tracked caret; initially the first mirror. *)
  val active_range : t -> range option
  val selection : t -> range option
  val choices : t -> string list option
  (** Wrap through choices, or choose first/last after custom text. Apply using
      [edits]/[applied]; the tracked occurrence remains selected afterwards. *)
  val cycle_choice : t -> direction -> revision:int -> text:Text_buffer.t -> change Or_error.t
  val cursor : t -> int
  val finished : t -> bool
  val matches : t -> revision:int -> text:Text_buffer.t -> bool

  (** Select the next/previous numbered field. Next after the last field finishes
      at $0. Previous at the first field stays there; finished sessions stay done. *)
  val navigate : t -> direction -> t

  (** Move within any occurrence of the active numbered field, clearing its
      selection. Reject offsets outside the field or inside a UTF-8 character.
      At a shared endpoint, prefer the currently tracked occurrence. *)
  val set_cursor : t -> int -> t Or_error.t

  (** Replace the selected default, or insert at the tracked caret. *)
  val insert : t -> revision:int -> text:Text_buffer.t -> string -> change Or_error.t

  (** Replace a range in the tracked active occurrence, synchronizing all mirrors.
      Edits use the supplied snapshot's coordinates and must be applied atomically.
      A change replaces the whole expanded snippet region in one edit, including
      coincident empty mirrors in template order. External edits/stale revisions
      are rejected. *)
  val replace
    : t -> revision:int -> text:Text_buffer.t -> start:int -> stop:int
    -> replacement:string -> change Or_error.t
  val edits : change -> Text_edit.t list
  val cursor_after : change -> int
  (** Call only after successful application of [edits], with the actual revision.
      The returned session has the resulting text and selection/caret. *)
  val applied : change -> revision:int -> t
end
