(** Normal-mode key bindings: a validated table from key sequences to what they ask
    for. {!Keymap} interprets the keys (counts, pending sequences, cancellation);
    this table only says which sequence means what, so a different table can be
    supplied in code without changing the keymap or the editor.

    {2 Validation}

    {!create} rejects a table that the keymap could not interpret unambiguously:

    - an empty sequence;
    - the same sequence bound twice;
    - a sequence that is a proper prefix of another: with no timeout, the shorter one
      could never run;
    - a sequence starting with a digit [1]–[9], which starts a count ([0] starts a
      count only after another digit, so a sequence may start with it);
    - a sequence containing [Escape] or [Ctrl-c], which always cancel. *)

(* [open! Core] would shadow our [Command] with Core's command-line [Command]. *)
module Editor_command := Ches_core.Command

open! Core
module Command := Editor_command

module Target : sig
  (** What a bound sequence asks for. Only [Move] of a motion that
      [Motion.takes_count] and [Scroll] of a scroll that [View_command.Scroll.takes_count]
      take a count; the keymap rejects a count before any other target, except
      [Paste], which repeats the register. *)
  type t =
    | Move of Ches_core.Motion.t (** [Command.Move], with the count if one was typed. *)
    | Editor of Command.t (** An editor command, which takes no count. *)
    | View of View_command.t (** A layout command, which takes no count. *)
    | Scroll of View_command.Scroll.t
    (** [View_command.Scroll], with the count if one was typed. *)
    | Delete_operator (** [d], whose following motion is parsed by the keymap. *)
    | Yank_operator (** [y], whose following motion is parsed by the keymap. *)
    | Delete_chars_forward (** [x], taking a count. *)
    | Delete_chars_backward (** [X], taking a count. *)
    | Delete_to_line_end (** [D], taking a count like [d$]. *)
    | Paste of { before : bool } (** [P] or [p], taking a count. *)
    | Find of { direction : Ches_core.Motion.Find.direction; till : bool }
    | Repeat_find of { opposite : bool }
    | Search_prompt of { forward : bool }
    | Repeat_search of { opposite : bool }
    | Search_word of { forward : bool }
    | Visual of [ `Characterwise | `Linewise ]
  [@@deriving sexp_of, equal]
end

type t [@@deriving sexp_of]

(** Validates the table; the error lists every problem found. *)
val create : (Key.t list * Target.t) list -> t Or_error.t

(** The bindings documented in {!Keymap}. *)
val default : t

type lookup =
  | Bound of Target.t
  | Prefix (** A proper prefix of at least one bound sequence. *)
  | Unbound

val find : t -> Key.t list -> lookup
