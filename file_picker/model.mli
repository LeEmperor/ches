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
  (** Conservative candidate/strings charge; counts even shared strings separately. *)
  val ownership_bytes : t -> int
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
  module Candidates : sig
    (** Immutable bytewise ordered set; append snapshots share trees, never hold
        predecessor snapshots. List compatibility is lazy, once per set. *)
    type t [@@deriving sexp_of]
    type stamp [@@deriving sexp_of]
    val create : unit -> t
    val length : t -> int
    val stamp : t -> stamp
    val append : t -> Candidate.t list -> t * Candidate.t list
    val to_list : t -> Candidate.t list
    val materialized : t -> bool
    val find : t -> string -> Candidate.t option
    val sequence : t -> Candidate.t Sequence.t
  end
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
  module Update : sig
    type t =
      { request : request; revision : int; base : Candidates.stamp; base_count : int
      ; candidates : Candidates.t; additions : Candidate.t list; status : status }
    [@@deriving sexp_of]
    val initial : request -> t
    val append : t -> status:status -> Candidate.t list -> t
  end
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

module Result_index : sig
  (** Immutable logical rows in fixed-size chunks, with bounded private alignment
      memoization. Lookups are logarithmic; count is constant time. A yielded
      producer builds without final linear copies. *)
  type t
  val empty : t
  val length : t -> int
  val alignment_byte_limit : int
  (** Index-owned arrays/maps/rows and reserved bounded alignment storage. Shared
      candidate/identity/preparation/query ownership must be charged separately. *)
  val retained_bytes : t -> int
  module Identity : sig
    (** One immutable raw-ID/ordinal index per candidate snapshot, shared by queries. *)
    type t
    module Builder : sig
      type identity = t
      type t
      val create : unit -> t
      val append : t -> Candidate.t -> unit
      val finish : t -> identity
      val snapshot : t -> identity
      val of_snapshot : identity -> t
    end
  end
  val belongs_to : t -> Identity.t -> bool
  (** Complete metadata enumeration; never aligns or truncates, original snapshot
      ordinals retained independently of rank order. *)
  val metadata : t -> (int * Candidate.t) Sequence.t
  module Tree : sig
    (** Persistent sorted ranking, append-only hidden score slots. Old snapshots
        expose only their frozen rank/identity roots, never later appended slots. *)
    type t
    val empty : t
    val add : t -> ordinal:int -> candidate:Candidate.t -> score:int -> t
  end
  val of_tree : identity:Identity.t -> root:string -> align:(Candidate.t -> int list) -> Tree.t -> t
  val of_candidates : root:string -> identity:Identity.t -> Discovery.Candidates.t -> t
  val tree : t -> Tree.t option
  module Builder : sig
    type index = t
    type t
    val create : unit -> t
    (** Compatibility eager builder: allocates at most one 128-slot result chunk
        and inserts one raw ID per appended record. Indexed producers instead use
        the shared-identity append variants below. *)
    val append : t -> Query_result.t -> unit
    (** Eager records, ordinal positions only; [finish] requires snapshot identity. *)
    val append_indexed : t -> ordinal:int -> Query_result.t -> unit
    (** Metadata only; populate ordinal-to-result positions without string map
        inserts. [finish] must receive the snapshot identity and pure aligner. *)
    val append_scored : t -> ordinal:int -> candidate:Candidate.t -> score:int -> unit
    (** Transfers ownership in constant time. Subsequent append attempts fail. *)
    val finish : ?identity:Identity.t -> ?align:(Candidate.t -> int list)
      -> ?alignment_byte_limit:int -> t -> index
  end
end

type 'token t

val create : token:'token -> discovery:Discovery.t -> 'token t
val token : 'token t -> 'token
val discovery : _ t -> Discovery.t
(** Metadata-only access does not force the compatibility candidate list. *)
val discovery_request : _ t -> Discovery.request
val discovery_status : _ t -> Discovery.status
val discovered_count : _ t -> int
val query : _ t -> string
(** Compatibility enumeration, materialized lazily once per result generation.
    Live navigation/rendering should use indexed access below. *)
val results : _ t -> Query_result.t list
val result_count : _ t -> int
val result_index : _ t -> Result_index.t
(** Logarithmic access; out-of-range positions return [None]. *)
val result_at : _ t -> int -> Query_result.t option
(** Clamp [start] to the collection and return at most [length] indexed entries.
    Negative lengths return []; no traversal of preceding/offscreen results. *)
val result_slice : _ t -> start:int -> length:int -> Query_result.t list
val selected_index : _ t -> int option
val selected_result : _ t -> Query_result.t option
(** Metadata access does not trigger alignment. [result_at]/[results] still return
    fully populated exact positions; row caching is bounded to 128 records and
    256 KiB charged payload. Oversized rows are returned exactly without caching. *)
val selected_candidate : _ t -> Candidate.t option
val selected : _ t -> Candidate.Id.t option

(** Replace metadata only. Caller must validate freshness and schedule new results. *)
val with_discovery : 'token t -> Discovery.t -> 'token t
val with_update : 'token t -> Discovery.Update.t -> 'token t

(** Install results supplied by a matcher. Preserve selected path identity if
    present; otherwise select the first result, or none for an empty list.
    Query sanitization, ranking, and snapshot freshness belong to later phases. *)
val with_results : 'token t -> query:string -> Query_result.t list -> 'token t
(** Publish a completed producer-owned index without enumerating/copying it. *)
val with_result_index : 'token t -> query:string -> Result_index.t -> 'token t

(** Select only an identity present in the current results. Invalid IDs leave the
    selection unchanged. This is not keyboard navigation. *)
val select : 'token t -> Candidate.Id.t -> 'token t
(** Constant-time selection by position. Out-of-range positions leave it unchanged. *)
val select_index : 'token t -> int -> 'token t

(** Pure intent construction; no selection produces no request. The host must
    close/release capture before delivering once to its consumer. Cancelling means
    discarding the model without calling the consumer. Repeated calls here are
    deliberately pure, not an exactly-once transport or a buffer manager. *)
val accept : 'token t -> 'token Request.t option

module For_testing : sig
  (** Work invariants: compatibility list is not forced by indexed consumers;
      result reads count only direct indexed retrievals, not count/ID lookups. *)
  val results_forced : _ t -> bool
  val indexed_reads : _ t -> int
  val alignment_count : _ t -> int
  val alignment_cache_size : _ t -> int
  val alignment_cache_bytes : _ t -> int
  val string_id_insertions : _ t -> int
  val same_identity : _ t -> _ t -> bool
end
