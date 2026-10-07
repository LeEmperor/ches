(** Headless file-picker contracts. Discovery, matching, interaction, and opening
    are separate consumers/producers of these values, not effects of this model. *)
open! Core

module Candidate : sig
  module Id : sig
    (** Exact absolute path bytes within a picker, not canonical filesystem identity.
        Symlink aliases and already-open-buffer deduplication belong to the buffer
        subsystem. No realpath, case folding, or filesystem access occurs here. *)
    type t [@@deriving sexp_of, equal, compare]

    val to_string : t -> string
  end

  type t [@@deriving sexp_of]

  (** [root] must be absolute; [relative_path] must be nonempty and relative,
      with no empty, [.] or [..] components. Both reject NUL. All other path bytes
      are retained, including invalid UTF-8, whitespace, and control bytes.
      This is lexical validation, not a symlink containment or existence check. *)
  val create : root:string -> relative_path:string -> t Or_error.t

  val id : t -> Id.t
  val root : t -> string
  val path : t -> string
  val relative_path : t -> string

  (** Valid single-line UTF-8 for rendering: backslashes are doubled, controls and
      malformed UTF-8 bytes are escaped as hexadecimal bytes. Never use this as
      an opening path. Highlight offsets must refer to this string, not raw paths. *)
  val display_path : t -> string

  (** The same safe encoding for untrusted root/error metadata, including NUL. *)
  val display_text : string -> string

  (** Map raw relative-path code-point starts to display code-point starts.
      A matched escaped scalar highlights its entire visible escape, including
      doubled backslashes and every hex escape byte. Sorted and deduplicated.
      Input must come from matching [relative_path], not arbitrary byte offsets. *)
  val display_positions : t -> raw_positions:int list -> int list
end

module Run_id : sig
  (** The provider/host allocates a fresh identity for every opening or refresh.
      Do not reuse a value while deliveries from its old run can still arrive. *)
  type t [@@deriving sexp_of, equal]

  val of_int : int -> t
end

module Discovery : sig
  type request =
    { run_id : Run_id.t
    ; root : string (** Explicit absolute project root; policy belongs to the provider. *)
    }
   [@@deriving sexp_of, equal]

  type status =
    | Loading (** No candidates received yet. *)
    | Partial (** Discovery is running with candidates available. *)
    | Complete of { truncated : bool } (** Empty candidates here means an empty project. *)
    | Failed of string (** May retain candidates discovered before the failure. *)
    | Cancelled
  [@@deriving sexp_of, equal]

  (** Provider snapshot, not an event protocol. The provider must enforce run/root
      consistency, deduplication, ordering, limits, and stale-delivery rejection. *)
  type t =
    { request : request
    ; candidates : Candidate.t list
    ; status : status
    }
  [@@deriving sexp_of]
end

module Query_result : sig
  (** Ranked by the matching producer, best first. Positions are zero-based UTF-8
      byte offsets of matched code-point starts in [Candidate.display_path]. *)
  type t =
    { candidate : Candidate.t
    ; score : int
    ; positions : int list
    }
  [@@deriving sexp_of]
end

module Request : sig
  (** Intent to open an EXISTING path or activate its buffer. Unlike startup
      [Controller.open_file], disappearance must fail, not create an empty file.
      [token] identifies the invoking host/session, not a guessed buffer API.
      Location support is intentionally absent until its coordinates are defined. *)
  type 'token t =
    { token : 'token
    ; path : string
    }
  [@@deriving sexp_of]
end

type 'token t

val create : token:'token -> discovery:Discovery.t -> 'token t
val token : 'token t -> 'token
val discovery : _ t -> Discovery.t
val query : _ t -> string
val results : _ t -> Query_result.t list
val selected : _ t -> Candidate.Id.t option

(** Replace metadata only. Caller must validate freshness and schedule new results. *)
val with_discovery : 'token t -> Discovery.t -> 'token t

(** Install results supplied by a matcher. Preserve selected path identity if
    present; otherwise select the first result, or none for an empty list.
    Query sanitization, ranking, and snapshot freshness belong to later phases. *)
val with_results : 'token t -> query:string -> Query_result.t list -> 'token t

(** Select only an identity present in the current results. Invalid IDs leave the
    selection unchanged. This is not keyboard navigation. *)
val select : 'token t -> Candidate.Id.t -> 'token t

(** Pure intent construction; no selection produces no request. The host must
    close/release capture before delivering once to its consumer. Cancelling means
    discarding the model without calling the consumer. Repeated calls here are
    deliberately pure, not an exactly-once transport or a buffer manager. *)
val accept : 'token t -> 'token Request.t option
