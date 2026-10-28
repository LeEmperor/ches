(** Commits (phase 5): the commit popup, the message file, and the checks shared by
    the view (before a message buffer opens) and {!Backend.plan} (before a commit
    runs). Pure, like the rest of this library: steps go out, reports come back.

    The flow, which the VCS view drives: the popup's [c] or [a] gives
    [Choice.Message]; the view checks {!refusal}, runs {!prepare} as a read job, and
    opens {!Prepared.t.message_file} with {!template} as an ordinary file buffer.
    [Space g c] saves it and runs {!Backend.plan} of [Finish_commit] ([git commit
    --cleanup=strip -F <file>]); [Space g a] drops it. The popup's [e] gives
    [Choice.Extend], planned at once as [Extend]. *)

open! Core
open Ches_vcs

module Kind : sig
  type t =
    | Commit (** A new commit of the staged changes. *)
    | Amend (** Replace HEAD with the staged changes and a new message (HEAD's
                pre-filled). *)
  [@@deriving sexp, equal]
end

(** What the commit popup's actions return. [flags] are the enabled switches' flags
    in the popup's declaration order ({!Ches_vcs.Popup.Action.t.run}). *)
module Choice : sig
  type t =
    | Message of
        { kind : Kind.t
        ; flags : string list
        } (** [c], [a]: write the message in a buffer first. *)
    | Extend of { flags : string list }
    (** [e]: [commit --amend --no-edit] at once: HEAD keeps its message and gains
        the staged changes. *)
  [@@deriving sexp, equal]
end

(** Title ["Commit"]. Switches, in order, no groups: [-n] ["--no-verify"] ["Disable
    hooks"], [-s] ["--signoff"] ["Add Signed-off-by line"], [-e] ["--allow-empty"]
    ["Allow an empty commit"]. Actions, in order: [c] ["Commit"] ([Message { kind =
    Commit; _ }]), [a] ["Amend"] ([Message { kind = Amend; _ }]), [e] ["Extend"]
    ([Extend _]). *)
val popup : Choice.t Popup.t

(** The flags {!popup} can give, in its order. *)
val flags : string list

(** Why the choice cannot commit from this status, or [None]. The view checks it when
    the popup's action is chosen (before a buffer opens, or before extend is planned);
    {!Backend.plan} checks it again when the commit runs. The first that applies:
    - a flag not in {!flags}: ["Unknown commit switch <flag>; nothing ran"];
    - any [Unmerged] entry: ["Resolve the conflicted files first (s marks one
      resolved); nothing ran"] (git refuses to commit with unmerged paths);
    - [Amend] or [Extend] on an unborn branch ([branch.oid = None]): ["Nothing to
      amend: there is no commit yet; nothing ran"];
    - [Commit] or [Extend] with nothing staged (no [Changed] or [Renamed_or_copied]
      entry whose index side is not [Unmodified]) and without ["--allow-empty"]:
      ["Nothing staged; stage changes first (s), or allow an empty commit (-e);
      nothing ran"].
    [Amend] with nothing staged is allowed: it rewords HEAD. *)
val refusal : Status.t -> Choice.t -> string option

(** The steps that find the message file and, for [Amend], HEAD's message, all
    [Run (Cli.read ~cwd:repo.root ...)]:
    - [rev-parse --git-path CHES_COMMIT_EDITMSG] (never [COMMIT_EDITMSG] itself,
      which git rewrites during [commit -F]);
    - [Amend] only: [log -1 --no-show-signature --format=%B HEAD --]. *)
val prepare : Repository.t -> Kind.t -> Job.Step.t list

module Prepared : sig
  type t =
    { message_file : string
    (** Absolute: git prints the path relative to the cwd unless the git directory
        is outside it, so a relative one is resolved against [repo.root]. *)
    ; head_message : string option
    (** [Amend]: HEAD's raw message ([%B]); [None] for [Commit]. *)
    }
  [@@deriving sexp_of, equal]
end

(** From [prepare]'s report: an error (one line, with the command line,
    {!Ches_vcs.Exec.Result.status_hum} and stderr, as {!Step_failure} gives it) when
    a step did not succeed, or the path is empty or not a single line. *)
val prepared
  :  Repository.t
  -> Kind.t
  -> Job.Step_report.t list
  -> Prepared.t Or_error.t

(** The message buffer's initial text, every line but the message a ['#'] comment
    ([git commit --cleanup=strip] removes them; the plan forces [core.commentChar=#]):
    {v
<HEAD's message for Amend, trailing blank lines and spaces removed; Commit: nothing>

# Write the commit message above. Lines starting with '#' are removed.
# Space g c commits; Space g a aborts.
#
# On branch <branch>            (or "HEAD detached at <7-char oid>",
#                                or "Initial commit on <branch>" when unborn)
# Switches: <flag> <flag>       (only when [flags] is not empty)
#
# Changes to be committed:      (Amend: "Staged changes added to HEAD:")
#	<label><path>
#	...                           (none staged: "#	(nothing staged)")
    v}
    For [Commit] the text starts with an empty line (the cursor's line), then the
    comment block: ["\n# Write ..."]; for [Amend], the message, an empty line, then
    the block (an amend message that is empty once trimmed gets [Commit]'s layout).
    The text ends with a newline. A HEAD message line starting with ['#'] is a comment
    here too, so amending drops it (as git's own amend does with the default
    [core.commentChar]). One line per staged entry in status
    order: [<label>] is git's, padded with spaces to 12 columns (["modified:   "],
    ["new file:   "], ["deleted:    "], ["renamed:    "], ["copied:     "],
    ["typechange: "]) after a tab; renames and copies read [<original> -> <path>].
    Paths (and the branch) with bytes other than printable ASCII are C-quoted as git
    quotes them (["\"a\\tb\""]); a non-UTF-8 HEAD message is kept as bytes. *)
val template
  :  Status.t
  -> Kind.t
  -> flags:string list
  -> head_message:string option
  -> string

(** The first non-empty stdout line of a finished commit step (["[main 1a2b3c4]
    Subject"]), for the success notice; [None] if there is none. *)
val summary : Job.Step_report.t list -> string option
