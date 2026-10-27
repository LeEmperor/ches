(** A list panel of the VCS view (git's Files, Branches, Commits): titled sections,
    each a header row followed by its items, and a cursor whose selection keeps its
    identity across snapshots. The backend builds panels from each snapshot and
    chooses the section ids and item keys; this module never interprets them. Item
    identity is the section plus the key (git: section and path, branch name, commit
    hash), so an item that moves to another section (a staged file) is a different
    item.

    Invariants the builder keeps (checked by {!validate}): section ids are unique in a
    panel, and keys are unique within a section. Functions here assume them; on a
    violation the first match wins. *)

open! Core

module Id : sig
  (** A panel within a backend's view, e.g. ["files"]. *)
  type t [@@deriving sexp, equal, compare]

  val of_string : string -> t
  val to_string : t -> string
end

module Section_id : sig
  (** A section within a panel, e.g. ["unstaged"]. *)
  type t [@@deriving sexp, equal, compare]

  include Comparable.S with type t := t

  val of_string : string -> t
  val to_string : t -> string
end

module Item : sig
  type 'a t =
    { key : string (** Identity within its section. *)
    ; value : 'a (** The backend's item (git: a status entry, a branch, a commit). *)
    }
  [@@deriving sexp_of]
end

module Section : sig
  type 'a t =
    { id : Section_id.t
    ; title : string (** The header row's text, e.g. ["Unstaged changes"]. *)
    ; items : 'a Item.t list (** In display order. *)
    }
  [@@deriving sexp_of]
end

type 'a t =
  { id : Id.t
  ; title : string
  ; sections : 'a Section.t list
  (** In display order. A backend may omit empty sections (git does); the cursor
      rule below handles a section that disappears. *)
  }
[@@deriving sexp_of]

(** Duplicate section ids, or duplicate keys within a section. *)
val validate : _ t -> unit Or_error.t

module Position : sig
  (** A row: a section's header, or an item. *)
  type t =
    | Header of Section_id.t
    | Item of
        { section : Section_id.t
        ; key : string
        }
  [@@deriving sexp, equal, compare]

  val section : t -> Section_id.t
end

val find_section : 'a t -> Section_id.t -> 'a Section.t option

(** The item at an [Item] position; [None] for a header or an absent item. *)
val find : 'a t -> Position.t -> 'a Item.t option

(** Whether the row exists (a header exists when its section does), folded or not. *)
val mem : _ t -> Position.t -> bool

type 'a panel := 'a t

module Cursor : sig
  (** A panel's selection and folded sections, kept by the view across snapshots.
      Folds are remembered by section id, including for sections absent from the
      current snapshot, so a section that reappears keeps its fold. An [Item]
      selection is never inside a folded section (folding moves it to the header). *)
  type t =
    { selected : Position.t option (** [None] only while the panel has no rows. *)
    ; folded : Section_id.Set.t
    }
  [@@deriving sexp, equal]

  (** Nothing selected, nothing folded. {!reconcile} selects the first row. *)
  val empty : t

  (** The visible rows in order: each section's header, then its items unless the
      section is folded. *)
  val rows : t -> _ panel -> Position.t list

  (** The selection after the panel changed from [previous] to [current] (a refresh,
      or an action that removed the selected item):

      - Still present (same section and key): kept. A header is kept while its
        section exists.
      - An item gone from a section that still exists: the next item of that section
        in [previous]'s order that is still in the section, else the nearest previous
        one that is, else the section's header.
      - Its section gone: the header of the nearest following section of [previous]
        that still exists, else of the nearest preceding one; if none, the first row.
      - Nothing selected: the first row ([None] when [current] has no rows).

      Items found in a folded section select its header instead. [previous] is the
      panel the selection was made in; folds are unchanged. *)
  val reconcile : t -> previous:'a panel -> current:'a panel -> t

  (** Select a row of the panel: an item of a folded section selects its header; a
      position not in the panel leaves the cursor unchanged. *)
  val select : t -> _ panel -> Position.t -> t

  (** Fold or unfold a section of the panel. Folding the section of the selected item
      selects its header. A section not in the panel leaves the cursor unchanged. *)
  val toggle_fold : t -> _ panel -> Section_id.t -> t
end
