(** Merges and rebases (phase 7): starting a merge, and continuing, skipping or
    aborting the rebase or merge in progress. Magit's keys: [m] is the merge popup
    ([m m] merges the branch selected in Branches; while merging, [m m] commits the
    merge and [m a] aborts), [r] the rebase popup while rebasing ([r r] continues,
    [r s] skips the commit being applied, [r a] aborts). Starting a rebase is not
    offered (a pull with [--rebase] is the way in). The commands are in {!Backend}'s
    "Merges, rebases and conflicts (phase 7)". *)

open! Core
open Ches_vcs

module Kind : sig
  type t =
    | Rebase
    | Merge
  [@@deriving sexp, equal]
end

(** What the popup of an operation in progress returns. *)
module Choice : sig
  type t =
    | Continue of Kind.t (** [r r]: [rebase --continue]; [m m]: commit the merge. *)
    | Skip (** [r s]: [rebase --skip]. *)
    | Abort of Kind.t (** [r a], [m a]. *)
  [@@deriving sexp, equal]
end

(** The popup while [kind] is in progress; no switches. [Rebase]: title
    ["Rebasing"], actions [r] ["Continue"], [s] ["Skip this commit"], [a] ["Abort"].
    [Merge]: title ["Merging"], actions [m] ["Commit the merge"], [a] ["Abort"]. *)
val popup : Kind.t -> Choice.t Popup.t

(** Whether [kind] is among [operations]: [Rebase] for {!In_progress.t.Rebase}
    (either backend; not [Apply_mailbox]), [Merge] for {!In_progress.t.Merge}. *)
val in_progress : In_progress.t list -> Kind.t -> bool

(** What the merge popup returns: the branch to merge ([None]: nothing usable was
    selected) and the enabled switches' flags in declaration order. *)
module Merge_choice : sig
  type t =
    { branch : string option
    ; flags : string list
    }
  [@@deriving sexp, equal]
end

(** The popup [m] opens while no merge is in progress, for [branch] (the Branches
    panel's selected branch, if any). Title ["Merge"]. Switches, in order, both in
    group ["fast-forward"] (so at most one is on): [-n] ["--no-ff"] ["Always create a
    merge commit"], [-f] ["--ff-only"] ["Fast-forward only"]. One action: [m]
    ["Merge <branch>"] (["Merge (select a branch in Branches first)"] with [None]),
    giving [{ branch; flags }]. *)
val merge_popup : branch:string option -> Merge_choice.t Popup.t

(** {!merge_popup}'s flags, in its order. *)
val merge_flags : string list

(** For a failed merge, pull or continue that stopped on conflicts: when the step
    [Ran], did not succeed, and its stdout or stderr contains ["CONFLICT ("] (git
    prints those lines on stdout), ["Stopped on conflicts: resolve each file (x, or
    Space x in the editor), mark it resolved with s, then continue"]; else [None]. *)
val stopped_hint : Job.Step_report.t -> string option
