(** The commands a user can run from the command palette, with the metadata used to
    find them. An entry names an existing editor or view action ({!Keymap.Action.t})
    rather than a key sequence: a command need not have a binding, and several
    bindings may run one command. Shortcut hints are derived from the active bindings
    by {!Shortcut}, never stored here.

    Entries are identified by {!Id.t}, which stays fixed while titles and keywords
    change; selection and execution use the ID, not a row or a label. The catalog is
    static: there is no runtime registration. *)

open! Core
open Ches_input

module Id : sig
  (** A stable, unique name such as ["view.toggle-relative-numbers"]: lowercase ASCII
      letters, digits, ['.'], and ['-']. {!create} rejects any other ID. *)
  type t [@@deriving sexp_of, equal, compare]

  val of_string : string -> t
  val to_string : t -> string
end

module Context : sig
  (** Where the palette was opened from, against which availability is checked. *)
  type t = { mode : Ches_core.Mode.t } [@@deriving sexp_of]
end

module Entry : sig
  type t [@@deriving sexp_of]

  (** [available] defaults to Normal mode only. *)
  val create
    :  id:string
    -> title:string
    -> ?description:string
    -> ?keywords:string list
    -> ?available:(Context.t -> bool)
    -> Keymap.Action.t
    -> t

  val id : t -> Id.t

  (** Shown in the palette and searched first, e.g. ["Toggle relative line numbers"]. *)
  val title : t -> string

  val description : t -> string option

  (** Searchable synonyms and abbreviations, e.g. ["gutter"] and ["rnu"]. *)
  val keywords : t -> string list

  val action : t -> Keymap.Action.t
  val is_available : t -> Context.t -> bool
end

type t [@@deriving sexp_of]

(** Validates the entries: the error lists every malformed or duplicate ID and every
    empty title. Entries keep their order, which breaks ties in search. *)
val create : Entry.t list -> t Or_error.t

(** The built-in commands. *)
val default : t

val entries : t -> Entry.t list
val find : t -> Id.t -> Entry.t option

(** The searchable fields of an entry. *)
module Field : sig
  type t =
    | Title
    | Id
    | Keyword
  [@@deriving sexp_of, equal]
end

type result = (Entry.t, Field.t) Fuzzy.Match.t

(** [search t context ~query] ranks the entries available in [context] against [query]
    with {!Fuzzy.rank}, matching each entry's title, then its ID, then each keyword,
    weighted in that order. An empty query lists the available entries in order. *)
val search : t -> Context.t -> query:string -> result list

(** The byte offsets of the title's matched code points, for highlighting. Empty when
    only the ID or keywords matched: those offsets do not apply to the title. *)
val title_positions : result -> int list
