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
  module Location : sig
    (** One-based line and terminal display-cell column; not byte/UTF-16 offsets. *)
    type t = { line : int; column : int } [@@deriving sexp_of, equal]
  end

  type t =
    { identity : Identity.t
    ; severity : Severity.t
    ; text : string
    ; attention : bool
    ; location : Location.t option
    }
  [@@deriving sexp_of, equal]
end

type t [@@deriving sexp_of]

type update =
  | Notify of Notification.t
  | Failed of Identity.t * Severity.t * string
  | Report of Identity.t * Severity.t * string * Problem.Location.t option
  (** Set/update an active problem and renew attention, optionally with a display
      location. [Failed] is the location-free file-operation shorthand. *)
  | Resolve of Identity.t
  | Command_completed
  | Acknowledge
  | Inspect_next
  | Inspect_identity of Identity.t
  | Acknowledge_identity of Identity.t
[@@deriving sexp_of]

val empty : t
val apply : t -> update -> t
val problems : t -> Problem.t list
val presented_problem : t -> Problem.t option
val notification : t -> Notification.t option
