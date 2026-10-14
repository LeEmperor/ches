(** In-process fuzzy matching of a query against candidates with several searchable
    fields, in the style of fzf. Pure, and independent of commands, the editor, and
    the screen, so it can search other collections later; it depends only on [Core].

    {2 Matching}

    The query is split on ASCII whitespace into tokens. A candidate matches when every
    token matches at least one of its fields; different tokens may match different
    fields. A token matches a field when the token's code points occur in the field
    in order, not necessarily next to each other: [rln] matches
    ["Toggle relative line numbers"]. Misspellings do not match.

    By default a match must also be good enough: its score (see below) must be at least half
    that of the token appearing contiguously at a word boundary. This keeps word
    initials such as [rln] and contiguous runs inside words such as [save] in
    ["unsaved"], but drops letters scattered through unrelated words, such as [abs]
    in ["relative numbers"]. A single code point always qualifies.

    {2 Normalization}

    ASCII letters are compared case-insensitively; every other code point, including
    non-ASCII letters, must be equal. Full Unicode case folding is not done. Malformed
    UTF-8 is decoded one byte at a time as U+FFFD, so any query or field is safe.

    {2 Ranking}

    A token's score in a field favours, in roughly this order: the token being the
    whole field, starting at the field's first character, contiguous runs of matched
    characters, and characters at word boundaries (after a space or punctuation, or a
    lowercase-to-uppercase or letter-to-digit change); gaps between matched
    characters cost a little. That score is scaled by the field's [weight], and the
    token takes its best field. A candidate's score is the sum over its tokens.
    Candidates with equal scores keep their input order.

    {2 Positions}

    Positions are byte offsets into a field's [text], each the start of a matched code
    point, so slicing at them never splits a code point. They are not display-cell
    columns. *)

open! Core

module Field : sig
  type 'tag t =
    { tag : 'tag (** The caller's name for the field, e.g. title or keyword. *)
    ; text : string
    ; weight : int
    (** Percentage applied to scores in this field; 100 leaves them unchanged. *)
    }
  [@@deriving sexp_of]
end

module Match : sig
  type ('item, 'tag) t =
    { item : 'item
    ; score : int
    ; positions : ('tag Field.t * int list) list
    (** Each field that some token matched, in the candidate's field order, with the
        sorted, distinct byte offsets matched in it. Empty for an empty query. *)
    }
  [@@deriving sexp_of]
end

module Policy : sig
  type t =
    | Command (** Existing 50-percent quality threshold; the default. *)
    | Loose_subsequence (** Accept every ordered subsequence, even negative scores. *)
  [@@deriving sexp_of, equal]
end

module Prepared : sig
  (** Immutable decoded fields, reusable across queries. Keep only the current
      collection; preparation adds three integer arrays per field. *)
  type ('item, 'tag) t

  val create : 'item * 'tag Field.t list -> ('item, 'tag) t
end

val rank_prepared
  :  ?policy:Policy.t
  -> query:string
  -> ('item, 'tag) Prepared.t list
  -> ('item, 'tag) Match.t list

(** [rank ~query candidates] are the candidates that match [query], best first, with
    ties in the order of [candidates]. A query with no tokens (empty or all
    whitespace) matches every candidate, in order, with score 0. *)
val rank
  :  ?policy:Policy.t
  -> query:string
  -> ('item * 'tag Field.t list) list
  -> ('item, 'tag) Match.t list

module Fast : sig
  (** Policy-equivalent score-only path. All offsets are in the original shared
      text. ASCII folding is unconditional, exactly as [rank]; no smart-case mode. *)
  module Query : sig
    type t
    val compile : string -> t
    val is_empty : t -> bool
    val equal : t -> t -> bool
    val retained_bytes : t -> int
    (** Proof for loose-subsequence token AND only: corresponding folded tokens
        extend by scalar prefix; additional tokens add constraints. *)
    val is_extension : previous:t -> next:t -> bool
  end
  module Text : sig
    type t
    val create : string -> t
    val retained_bytes : t -> int
  end
  module Field : sig
    type t
    (** A suffix view; [byte_start] must be a scalar boundary. At a file basename
        boundary the previous slash supplies the same bonus as a fresh field. *)
    val create : Text.t -> byte_start:int -> weight:int -> t
  end
  module Scratch : sig
    type t
    (** Optional lower traceback budget supports bounded equivalence probes. *)
    val create : ?trace_limit:int -> unit -> t
    val capacity : t -> int
    val trace_capacity : t -> int
    val scoring_calls : t -> int
    val alignment_calls : t -> int
  end
  val no_match : int
  val score : ?policy:Policy.t -> Scratch.t -> Query.t -> Field.t array -> int
  (** Only request positions for matching candidates. Ties/alignments equal [rank].
      Traceback uses at most 262,144 cells; larger cases recompute prefix rows. *)
  val positions : ?policy:Policy.t -> Scratch.t -> Query.t -> Field.t array -> int list
end
