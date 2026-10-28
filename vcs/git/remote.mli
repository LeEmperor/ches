(** Push, pull and fetch (phase 6): the push and pull popups, and the hints that
    explain a failed network command. Pure, like the rest of this library: the view
    asks the popups ({!Ches_vcs.Popup}) and hands their choices to {!Backend.plan}
    ([Push], [Pull]); [f] is planned at once ([Fetch]). The commands themselves are
    in {!Backend}'s "Remotes and branches (phase 6)". *)

open! Core
open Ches_vcs

module Push : sig
  module Target : sig
    type t =
      | Upstream (** [p]: the current branch's configured upstream. *)
      | Set_upstream (** [u]: [origin/<branch>], which becomes its upstream. *)
    [@@deriving sexp, equal]
  end

  (** What the push popup's actions return. [flags] are the enabled switches' flags
      in the popup's declaration order. *)
  module Choice : sig
    type t =
      { target : Target.t
      ; flags : string list
      }
    [@@deriving sexp, equal]
  end

  (** Built for [status] (the descriptions name the targets). Title ["Push <branch>"]
      ([status.branch.head]; ["Push"] when detached). Switches, in order, no groups:
      [-f] ["--force-with-lease"] ["Force with lease (confirmed)"], [-n]
      ["--no-verify"] ["Disable hooks"]. Actions, in order: [p] ["Push to
      <upstream>"] ([status.branch.upstream], e.g. ["Push to origin/main"]; ["Push to
      upstream (none set)"] without one), [u] ["Push to origin/<branch>, set
      upstream"] (["Push to origin, set upstream"] when detached). Detached or
      without an upstream the popup still opens: {!Backend.plan} refuses the choice
      with the reason. *)
  val popup : Status.t -> Choice.t Popup.t

  (** The flags {!popup} can give, in its order. *)
  val flags : string list
end

module Pull : sig
  module Choice : sig
    type t = { flags : string list } [@@deriving sexp, equal]
  end

  (** Title ["Pull"]. One switch: [-r] ["--rebase"] ["Rebase local commits onto the
      upstream"]; without it the pull only fast-forwards. One action: [p] ["Pull from
      <upstream>"] (["Pull from upstream (none set)"] without one). *)
  val popup : Status.t -> Choice.t Popup.t

  val flags : string list
end

(** For a failed network command's notice: a one-line explanation of git's stderr,
    or [None] (the view then shows git's first stderr line). [None] unless the step
    [Ran] and did not succeed. The first rule whose text occurs in stderr
    (case-sensitive substrings; git's and ssh's untranslated messages) wins:
    - ["Permission denied (publickey"]: ["SSH refused the key: is one loaded in
      ssh-agent (ssh-add -l)?"]
    - ["Host key verification failed"]: ["SSH does not know the host's key: connect
      once with ssh in a terminal to accept it"]
    - ["terminal prompts disabled"], ["could not read Username"] or ["could not read
      Password"]: ["Git needs credentials and Ches cannot prompt: use an SSH key in
      ssh-agent or a credential helper"]
    - ["Could not resolve hostname"] or ["Could not resolve host"]: ["Could not
      resolve the remote's host: check the network"]
    - ["Not possible to fast-forward"]: ["The branch and its upstream have diverged:
      pull with rebase (p -r p) or merge outside Ches"]
    - ["(stale info)"]: ["The remote branch moved since the last fetch: fetch (f)
      and look before forcing"]
    - ["(fetch first)"] or ["(non-fast-forward)"]: ["The remote has commits this
      branch lacks: pull first (p p)"]
    - ["does not appear to be a git repository"] or ["No remote repository
      specified"]: ["The remote is missing or unreachable: check git remote -v"] *)
val hint : Job.Step_report.t -> string option
