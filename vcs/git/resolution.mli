(** Resolving a whole conflicted file by taking one side (phase 7): [x] on a
    Conflicted item opens this popup. Resolving hunk by hunk is the editor's job, on
    the file's conflict markers ([Space x] keeps the upper, lower, both or base
    side). Magit's way: taking a side also stages the file (marks it resolved).

    "Ours" is git's [--ours]: HEAD while merging, but the upstream being rebased
    onto while rebasing; "theirs" is the merged branch, or the commit being applied
    while rebasing. The descriptions say which. *)

open! Core
open Ches_vcs

module Side : sig
  type t =
    | Ours (** [o] *)
    | Theirs (** [t] *)
    | Markers (** [m]: write the conflict markers again ([checkout --merge]). *)
  [@@deriving sexp, equal]
end

(** Which sides of a conflict have the file: [Both_modified], [Both_added] both;
    [Added_by_us], [Deleted_by_them] ours only; [Added_by_them], [Deleted_by_us]
    theirs only; [Both_deleted] neither. Taking a side without the file deletes it. *)
val has_file : Status.Conflict.t -> Side.t -> bool

(** The labels of the sides, from the first operation in progress: [Rebase]: ours
    ["the upstream"], theirs ["your commit"]; [Merge { head }]: ours ["HEAD"], theirs
    the 7-character [head] (["the merged branch"] when unknown); otherwise ours
    ["HEAD"], theirs ["the other side"]. *)
val labels : In_progress.t list -> string * string

(** Title ["Resolve <path>"] (the path as given, raw). No switches. Actions, in
    order: [o] ["Take ours (<ours label>)"], [t] ["Take theirs (<theirs label>)"]
    (["Take ours: delete the file (<label>)"] when that side has no file, see
    {!has_file}), and only for [Both_modified] and [Both_added], [m] ["Restore the
    conflict markers"]. *)
val popup
  :  path:string
  -> Status.Conflict.t
  -> In_progress.t list
  -> Side.t Popup.t
