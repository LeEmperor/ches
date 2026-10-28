(** Aborting a rebase or merge in progress (phase 6). A pull with [--rebase] can stop
    on a conflict; a merge may have been started outside Ches. Resolving and
    continuing are deferred (tier 2); abort is the one way out offered. Magit's keys:
    [r] (rebase popup) and [m] (merge popup), each with only [a] for now. *)

open! Core
open Ches_vcs

module Operation : sig
  type t =
    | Rebase
    | Merge
  [@@deriving sexp, equal]
end

(** Title ["Rebasing"] or ["Merging"]; no switches; one action: [a] ["Abort"],
    giving the operation. *)
val popup : Operation.t -> Operation.t Popup.t

(** Whether the operation is among [operations]: [Rebase] for
    {!In_progress.t.Rebase} (either backend; not [Apply_mailbox]), [Merge] for
    {!In_progress.t.Merge}. *)
val in_progress : In_progress.t list -> Operation.t -> bool
