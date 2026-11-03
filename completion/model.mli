open! Core
open Ches_core

module Token : sig
  type t =
    { resource : string
    ; generation : int
    ; revision : int
    ; request : int
    }
  [@@deriving sexp_of, equal]
end

module Candidate : sig
  type source = Buffer | Lsp of string | Snippet [@@deriving sexp_of, equal]
  (** Edits use the session's base snapshot. [cursor] is a byte boundary within
      [primary.text], not an absolute document offset. When [snippet] is present,
      [primary.text] must equal [Snippet.text snippet]. *)
  type t =
    { id : string
    ; source : source
    ; label : string
    ; detail : string option
    ; filter_text : string
    ; sort_text : string
    ; primary : Text_edit.t
    ; additional : Text_edit.t list
    ; cursor : int
    ; snippet : Snippet.t option
    }
  [@@deriving sexp_of, equal]
end

module Request : sig
  type trigger = Automatic | Character of string | Incomplete
  [@@deriving sexp_of, equal]
  type t =
    { token : Token.t
    ; cursor : int
    ; fallback_start : int
    ; fallback_stop : int
    ; trigger : trigger
    }
  [@@deriving sexp_of, equal]
end

module Reply : sig
  type t =
    { token : Token.t
    ; source : string
    ; candidates : Candidate.t list
    ; incomplete : bool
    }
  [@@deriving sexp_of, equal]
end

module Buffer_words : sig
  type t
  (** Synchronous legacy/batch API. Index the whole snapshot, with storage proportional to distinct word bytes.
      The immutable index belongs to this exact text snapshot. *)
  val create : Text_buffer.t -> t
  (** Synchronous legacy/batch API. Reuse an index across edits. Recent local edits scan only the changed region
      expanded to complete identifier boundaries, not the whole document.
      Unrelated snapshots or edits beyond the text buffer's bounded history may
      require a whole-document comparison. Identity-only changes reuse the words.
      Cache the returned index per buffer, replacing the previous value. *)
  val update : t -> Text_buffer.t -> t
  module Builder : sig
    type index = t
    type t
    val create : ?before:index -> Text_buffer.t -> t
    (** Budget covers scalar bytes, key allocation and estimated worst-case
        balanced-tree comparisons. A step may overshoot by one scalar and one
        atomic map operation (keys are capped at 4096 bytes). *)
    val step : t -> budget:int -> index option
  end
  val update_bounded : t -> Text_buffer.t -> budget:int -> t option
  (** Case-sensitive prefix matches in lexical order, independent of proximity.
      Empty prefixes match all words, up to [limit]; the sole occurrence of the
      current word is excluded even at its start. Reads at most 4096 prefix bytes.
      A mismatched index yields no candidates. *)
  val candidates : t -> text:Text_buffer.t -> cursor:int -> limit:int -> Candidate.t list
  module For_testing : sig
    (** Result and total bytes tokenized by [create]/[update], plus bytes visited
        by Builder steps (including comparison/boundary work), in this scope.
        Excludes prefix queries and the legacy update's fallback comparison. *)
    val measure : (unit -> 'a) -> 'a * int
  end
end

type t
type plan
type direction = Next | Previous [@@deriving sexp_of, equal]
type ghost = { at : int; text : string } [@@deriving sexp_of, equal]

(** Empty prefixes are permitted for server-triggered completion. Callers control
    when to start; automatic empty-prefix sessions should normally be suppressed.
    [prefer_local_snippets] defaults to [true]; [false] ranks LSP suggestions
    ahead of local snippets without excluding either source. *)
val start
  :  ?prefer_local_snippets:bool
  -> token:Token.t
  -> text:Text_buffer.t
  -> cursor:int
  -> ?words:Buffer_words.t
  -> limit:int
  -> unit
  -> (t * Request.t) option

(** Ignore mismatched tokens and all replies after the first application. Replace
    this provider's contribution, validate against base, preserve selection.
    Inspect at most 1000 candidates per reply, matching [filter_text] against the
    original identifier prefix case-sensitively before applying the menu limit.
    An empty prefix matches all candidates. Within each source priority, parsed
    templates rank before plain words; deduplication preserves distinct placeholder
    semantics. *)
val receive : t -> Reply.t -> t
(** Exact original token/cursor and physical base snapshot only. Preserves
    provider ordering/selection; ignored after installation/finalization. *)
val receive_words : t -> Request.t -> Buffer_words.t -> t
val candidates : t -> Candidate.t list
val selected : t -> Candidate.t option
(** First press inserts the selected primary in either direction; later presses
    cycle/wrap, replacing only the primary. Additional edits are deferred. *)
val plan : t -> direction -> plan option
(** Only after a primary has been installed. Atomically reverse that primary and
    apply the full candidate. Returns None after finalization or without extras.
    A finalized session must be discarded by its owner. *)
val finalize : t -> plan option
val edits : plan -> Text_edit.t list list
(** Absolute final document byte offset. *)
val cursor : plan -> int
(** Acknowledge only successful application (including no-op). A stale/foreign
    plan raises Invalid_argument. No state is advanced before acknowledgement. *)
val applied : t -> plan -> revision:int -> t
val matches : t -> revision:int -> cursor:int -> bool
val ghost : t -> ghost option
