(** Discovery-independent, synchronous file ranking. Match raw basename (weight
    150) and project-relative path (100), using the shared loose-subsequence policy.
    Every whitespace-separated token must match a field; this is not typo correction
    or full fzf syntax. ASCII case folding only. Ties and empty queries preserve
    discovery input order, so pass the provider's deterministically sorted snapshot.
    No filesystem IO, controller effects, asynchronous tasks, or implicit cache. *)
open! Core

type t
type prepared
type query
type scratch
val prepare_candidate : Model.Candidate.t -> prepared
(** Reuse compact fields but release the old candidate object on snapshot changes. *)
val rebind : prepared -> Model.Candidate.t -> prepared
val compile : string -> query
val is_blank : query -> bool
val same_query : query -> query -> bool
val is_extension : previous:query -> next:query -> bool
val query_bytes : query -> int
val scratch : unit -> scratch
val no_match : int
val score : scratch -> query -> prepared -> int
(** Reconstruct exact display offsets on demand for a candidate accepted by [score].
    Captures no mutable scoring job; blank queries return no positions. *)
val positions : query -> prepared -> int list
val retained_bytes : prepared -> int
(** Conservative compact data/record/header charge, excluding the separately
    accounted candidate and preparation-map node. *)
val ownership_bytes : prepared -> int

(** Decode fields once per candidate collection, then reuse across query edits.
    Replace/release the old collection when discovery changes. Incremental cache
     reuse belongs to Interaction. Storage is shared by basename/path suffix views;
     ASCII uses two byte strings, UTF-8 uses scalar/offset arrays and bonus bytes. Results are
    not capped. *)
val prepare : Model.Candidate.t list -> t

(** Best first, with sorted distinct byte offsets into the escaped display path.
    All matched tokens' highlights are merged, including basename-to-path offsets.
    Synchronous: the host owns query scheduling and discovery/run freshness. *)
val rank : query:string -> t -> Model.Query_result.t list
