(** A command a focused view offers while it is in a given state: a stable name,
    the keys that run it in that view, and a description. Views declare these for
    help and for the command palette; running one by name must do exactly what its
    keys do, so a declared key sequence must reach the view's own action (not the
    host's Escape, Tab, or leader handling). Like the rest of this library it names
    no content type. *)

open! Core
open Ches_input

type t =
  { name : string
  (** Unique within the view, stable across states: lowercase ASCII letters, digits,
      ['.'] and ['-'] (so it can form a palette entry id), e.g. ["toggle-details"]. *)
  ; keys : Key.t list (** The sequence that runs it while the view is focused. *)
  ; description : string (** A short imperative title, e.g. ["Toggle details"]. *)
  }
[@@deriving sexp_of, equal]

val create : string -> keys:Key.t list -> string -> t

(** Whether [name] is a well-formed command name. *)
val valid_name : string -> bool

(** The keys for display, e.g. ["g g"], ["Ctrl-d"], ["Enter"]. *)
val keys_hum : t -> string
