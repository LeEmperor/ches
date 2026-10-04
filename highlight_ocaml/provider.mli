open! Core
open Ches_highlight

(** Synchronous, privately owned OCaml parser/query session. Never put it in editor
    history or render state. Not safe for concurrent calls. Every invocation resets
    the parser and parses the complete source without a prior tree. *)
type t

module Failure : sig
  type t =
    | Unsupported_language
    | Initialization of string
    | Parsing of string
    | Closed
    | Key_mismatch
    | Invalid_utf8
    | Source_too_large
  [@@deriving sexp_of, equal]
end

module Status : sig
  type t = Highlighted of { syntax_errors : bool } | Plain of Failure.t
  [@@deriving sexp_of, equal]
end

type result = { snapshot : Snapshot.t; status : Status.t }

(** Pinned provider/query version; include it in highlight freshness keys. *)
val configuration : string
val create : language:Language.t -> t

(** Constructs the provider's language/configuration key. The caller supplies
    authoritative identity and revision for the source it will pass to highlight. *)
val key : t -> document:Snapshot.Document_id.t -> revision:int -> Snapshot.Key.t

(** Malformed OCaml is queried normally and may produce useful highlights.
    Provider/input/key failure returns an empty CURRENT snapshot and a status,
    never a previous result. Expected binding exceptions are caught; process-fatal
    exceptions such as out-of-memory are not hidden. A parse/query failure disables
    the session; recreate it for an explicit retry. No logging or editor feedback. *)
val highlight : t -> key:Snapshot.Key.t -> source:string -> result

(** Drop owned parser/query references. Idempotent; closed sessions return Plain.
    The binding has no explicit parser/query/tree disposal: native release relies
    on its GC finalizers. Per-call trees/cursors are not retained by this provider;
    no forced GC is performed in production. *)
val close : t -> unit

(** Number of actual parse attempts in this session, including binding failures.
    Reading diagnostics is observational and performs no provider work. *)
val parse_count : t -> int

module For_testing : sig
  (** Deliberately invalid/missing/predicate queries exercise initialization fallback.
      Not a user-query configuration API. Uses a separate configuration key. *)
  val create_with_query : language:Language.t -> query_source:string option -> t
  (** Injects a binding-style Failure inside the next parse operation. *)
  val fail_next_parse : t -> unit
  (** Checks the binding's uint32 byte-length limit without allocating huge text. *)
  val supported_length : int -> bool
end
