(** Pure feedback lifecycle, shared by all views. Problems are keyed by source, operation,
    and resource, in first-occurrence order. Acknowledgement never resolves a problem;
    inspection cycles without renewing attention or retrying. *)
open! Core

module Severity : sig
  type t =
    | Info
    | Warning
    | Error
  [@@deriving sexp_of, equal]
end

module Identity : sig
  type kind =
    | Save
    | Reload
  [@@deriving sexp_of, equal]

  type t =
    { source : string
    ; kind : kind
    ; resource : string
    }
  [@@deriving sexp_of, equal]
end

module Notification : sig
  type t =
    { source : string
    ; scope : string option
    ; severity : Severity.t
    ; text : string
    }
  [@@deriving sexp_of, equal]
end

module Problem : sig
  type t =
    { identity : Identity.t
    ; severity : Severity.t
    ; text : string
    ; attention : bool
    }
  [@@deriving sexp_of, equal]
end

type t [@@deriving sexp_of]

type update =
  | Notify of Notification.t
  | Failed of Identity.t * Severity.t * string
  | Resolve of Identity.t
  | Command_completed
  | Acknowledge
  | Inspect_next
[@@deriving sexp_of]

val empty : t
val apply : t -> update -> t
val problems : t -> Problem.t list
val presented_problem : t -> Problem.t option
val notification : t -> Notification.t option
