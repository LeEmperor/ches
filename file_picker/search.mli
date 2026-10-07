(** Discovery-independent, synchronous file ranking. Match raw basename (weight
    150) and project-relative path (100), using the shared loose-subsequence policy.
    Every whitespace-separated token must match a field; this is not typo correction
    or full fzf syntax. ASCII case folding only. Ties and empty queries preserve
    discovery input order, so pass the provider's deterministically sorted snapshot.
    No filesystem IO, controller effects, asynchronous tasks, or implicit cache. *)
open! Core

type t

(** Decode fields once per candidate collection, then reuse across query edits.
    Replace/release the old collection when discovery changes. Incremental cache
    reuse is not yet implemented. Storage is linear in path bytes; results are
    not capped. *)
val prepare : Model.Candidate.t list -> t

(** Best first, with sorted distinct byte offsets into the escaped display path.
    All matched tokens' highlights are merged, including basename-to-path offsets.
    Synchronous: the host owns query scheduling and discovery/run freshness. *)
val rank : query:string -> t -> Model.Query_result.t list
