(** Current in-memory document snapshot and bounded-turn fuzzy line interaction.
    No filesystem reads. Host owns scheduling, capture and controller installation. *)
open! Core

type result =
  { line : int (** One-based, also stable identity within this snapshot. *)
  ; text : string (** Raw line, without LF. *)
  ; score : int
  ; positions : int list (** Raw line UTF-8 byte starts, not display columns. *)
  }

type t
val create : Ches_app.Controller.t -> t
val query : t -> string
val results : t -> result list
val selected : t -> int option
val busy : t -> bool
val closed : t -> bool
val invalidated : t -> bool
val truncated : t -> bool
val line_count : t -> int
val prepared_count : t -> int
(** Freshness includes runtime identity, revision and immutable text identity.
    A mismatch permanently invalidates this session, drops all work/results/text;
    reopen explicitly to refresh. Call on controller changes and before rendering. *)
val validate : t -> Ches_app.Controller.t -> bool
val update : t -> Ches_palette.Palette.Event.t -> unit
(** At most [budget] line/output records per turn. Limits: first 50k lines,
    8 MiB raw line payload, 4 KiB per line. Stop at the first exceeded limit;
    never silently skip a long line. Per-record DP/GC is not time bounded. *)
val work : t -> budget:int -> unit
val cancel : t -> release:(unit -> unit) -> unit
(** Pending/empty/closed Enter is inert. Stale Enter returns an error, without
    jumping. Success closes once, releases capture, then rereads [current] and
    revalidates before calling Controller.jump. Returned controller must be
    installed by the host synchronously; no cross-document opening. *)
val accept
  : t
  -> current:(unit -> Ches_app.Controller.t)
  -> release:(unit -> unit)
  -> Ches_app.Controller.t option Or_error.t
