(** Pure feedback lifecycle, shared by all views. Problems are keyed by source, operation,
    and resource, in first-occurrence order. Acknowledgement never resolves a problem;
    inspection cycles without renewing attention or retrying. A bounded {!History} of
    past feedback is kept beside, never mixed into, the active problems. *)
open! Core

module Severity : sig
  type t =
    | Hint (** The language-server protocol's lowest severity, kept distinct as Neovim does. *)
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
    ; history : bool
    (** Kept in {!History}: action feedback such as editor messages and keymap
        notices. Layout feedback and a view's own notices (a rejected paste, say) are
        not. *)
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

(** Bounded, chronological, in-memory history of notifications and problem lifecycle
    events. It is a log of what happened, not state to act on: entries are never
    acknowledged or resolved, resolving a problem adds an entry rather than removing
    its earlier ones, and clearing the history leaves active problems alone. Only
    {!apply} records, so rendering, resizing, and animation never add entries. *)
module History : sig
  module Event : sig
    type t =
      | Notified of Notification.t (** One with [history = true]. *)
      | Reported of
          { identity : Identity.t
          ; severity : Severity.t
          ; text : string
          ; location : Problem.Location.t option
          ; again : bool (** The identity was already active: a repeated failure. *)
          }
      | Resolved of
          { identity : Identity.t
          ; severity : Severity.t
          ; text : string (** The problem's last text. *)
          }
    [@@deriving sexp_of, equal]
  end

  module Entry : sig
    type t =
      { seq : int
      (** Chronological identity: increasing from 1 and never reused, also after
          {!clear}, so a view can key its selection on it. *)
      ; event : Event.t
      ; count : int
      (** Consecutive identical occurrences merged into this entry; at least 1. *)
      }
    [@@deriving sexp_of, equal]
  end

  type t [@@deriving sexp_of]

  (** 200 entries. Recording past it evicts the oldest. *)
  val capacity : int

  val empty : t

  (** Append [event], or, when it is identical to the newest entry's (ignoring
      [again]), count it there. That entry keeps its [seq] and place. *)
  val record : t -> Event.t -> t

  (** Remove every entry; [seq]s keep increasing. *)
  val clear : t -> t

  (** Oldest first. *)
  val entries : t -> Entry.t list

  (** Entries evicted for capacity since the last {!clear}. *)
  val dropped : t -> int
end

(** Diagnostic findings kept as standing state: one collection per (source, resource),
    replaced whole by each new snapshot. They are not problems: they never take attention,
    are never acknowledged, and are not recorded in {!History}. A source stopping is a
    one-off warning, as in Neovim, not a problem; its findings are kept, marked as from an
    ended session, until the restarted source replaces them. *)
module Diagnostics : sig
  module Finding : sig
    type t =
      { severity : Severity.t
      ; message : string
      ; location : Problem.Location.t option
      }
    [@@deriving sexp_of, equal]
  end

  module Basis : sig
    (** The document revision a collection describes: the one the source reported, or,
        for an unversioned source, the editor revision current when it arrived. *)
    type t =
      | Reported of int
      | Arrived_at of int
    [@@deriving sexp_of, equal]

    val revision : t -> int
  end

  module Collection : sig
    type t =
      { source : string
      ; resource : string
      ; basis : Basis.t
      ; findings : Finding.t list (** Never empty when returned by {!collections}. *)
      ; session_ended : bool
      (** Computed by a source session that has since stopped; cleared by the next
          snapshot for this collection. *)
      }
    [@@deriving sexp_of, equal]

    (** The collection's basis revision is older than [revision]. Only meaningful for
        the open document, the only resource with revisions. *)
    val behind : t -> revision:int -> bool
  end

  type t [@@deriving sexp_of]

  (** Non-empty collections, sorted by resource then source. *)
  val collections : t -> Collection.t list

  (** The source has stopped and not restarted. *)
  val stopped : t -> source:string -> bool
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
  | Clear_history (** Empty {!history}; active problems and attention are unchanged. *)
  | Diagnostics_received of
      { source : string
      ; resource : string
      ; revision : int option (** As reported by the source; [None] if unversioned. *)
      ; current_revision : int (** The editor's revision when the snapshot is applied. *)
      ; findings : Diagnostics.Finding.t list
      }
  (** Replace the (source, resource) collection; an empty list clears it. A snapshot
      reporting a revision older than the stored reported one is dropped; an equal one
      replaces it. *)
  | Source_started of { source : string; root : string }
  (** Clear the source's stopped state. Its kept findings stay [session_ended] until
      replaced. *)
  | Source_stopped of { source : string; root : string; reason : string }
  (** Mark the source stopped and keep its findings as [session_ended]. Notify a
      Warning recorded in history, which, like any notification, goes at the next
      command; no problem is reported and nothing takes attention. *)
  | Source_unavailable of { source : string; root : string; reason : string }
  (** The source could not be started at all, such as a server missing from PATH: only
      record an Error in history, where Neovim would only write its log. *)
[@@deriving sexp_of]

(** Records into {!history}: a [Notify] with [history = true]; every [Report]/[Failed]
    (with [again] when the identity was active); a [Resolve] of an active identity;
    [Source_stopped] and [Source_unavailable]. Nothing else records, including
    acknowledgement and inspection. *)

val empty : t
val apply : t -> update -> t
val problems : t -> Problem.t list
val presented_problem : t -> Problem.t option

(** The presented problem as a notification (with [history = false]: it is a view of
    the problem, not a new event), else the transient one. *)
val notification : t -> Notification.t option

val history : t -> History.t
val diagnostics : t -> Diagnostics.t
(** Actual document close: forget diagnostic snapshots and their revision guards,
    without erasing operation feedback or history. *)
val forget_resource : t -> string -> t
