(** Shortcut hints for palette entries, derived from a Normal-mode binding table so
    they always reflect the active bindings rather than a second copy of the defaults.

    The table is supplied as the [(keys, target)] pairs that {!Bindings.create}
    validates. Only targets that are complete actions on their own, [Editor] and
    [View], can show as a shortcut; operators, prompts, and other targets that need
    further keys never do. *)

open! Core
open Ches_input

(** [sequences bindings action] are the key sequences in [bindings] that run exactly
    [action], in the order of [bindings]. *)
val sequences : (Key.t list * Bindings.Target.t) list -> Keymap.Action.t -> Key.t list list

(** A sequence for display, e.g. ["Space v N"] or ["Ctrl-r"]. *)
val to_string_hum : Key.t list -> string
