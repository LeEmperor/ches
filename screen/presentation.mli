open! Core

(** Effective presentation, independent of retained workspace preferences. *)
type t = Workspace | Zen | Bare [@@deriving sexp_of, equal]

(** Retained independently of workspace geometry, including while Bare is inactive. *)
module Bare_prefs : sig
  type t = { line_numbers : Line_numbers.t } [@@deriving sexp_of, equal]

  (** Bare starts without line numbers. *)
  val default : t
end

val suppress_workspace : t -> bool
