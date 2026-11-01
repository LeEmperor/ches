(** Which history the Commits panel lists (phase 8): part of every refresh
    ({!Backend.Refresh.t.log}), so the log a mutation changes is re-read with the rest.
    Backend-agnostic: a branch is a name the backend understands, a path is relative to
    the repository root. The view keeps one and changes it from its log popup ([l]),
    [+], and [Space g l]. *)

open! Core

module Range : sig
  type t =
    | Head (** The current branch, or the detached HEAD. *)
    | Branch of string (** A local branch, by name. *)
    | All (** HEAD and every local and remote-tracking branch. *)
  [@@deriving sexp, equal]
end

type t =
  { range : Range.t
  ; path : string option
  (** File history: only the commits that changed this path (relative to the root),
      following renames. No graph is drawn for it (see {!graph_shown}). *)
  ; graph : bool (** Draw the graph ({!Graph}), reading commits in topological order. *)
  ; merges : bool (** [false]: omit merge commits. *)
  ; first_parent : bool (** Follow only the first parent of merges. *)
  ; limit : int (** Commits read; positive. *)
  }
[@@deriving sexp, equal]

(** [Head], no path, graph on, merges shown, every parent, [default_limit]. *)
val default : t

(** 200. *)
val default_limit : int

(** 12800: {!more} stops here. *)
val max_limit : int

(** [limit] doubled, at most {!max_limit}; [None] when already there ([+]). *)
val more : t -> t option

(** Whether the view draws a graph for this scope: [graph], no [path] and [merges]
    (omitting merges leaves lanes that never join). With [first_parent] the graph is
    drawn from first parents only. *)
val graph_shown : t -> bool

(** The Commits section's title for a scope whose read gave [shown] commits:
    ["History of <path>"] with a path, else [Head] ["Recent commits"], [Branch b]
    ["Commits on <b>"], [All] ["All branches"]; then, when any applies, the
    qualifiers in parentheses, comma-separated, in this order: ["no merges"] (not
    [merges]), ["first parent"], ["first <limit>"] (when [shown >= limit], so there
    may be more). E.g. ["Commits on main (no merges, first 200)"]. Paths and names
    are raw. *)
val title : t -> shown:int -> string
