(** The synthetic diagnostic producer ([--synthetic-checker]), speaking the same
    boundary messages a language-server client will. Like ocamllsp it is one source,
    {!source}, running two checks and merging them into one list per file:

    - an edit check, like merlin: {!Config.edit_delay} after a change it checks the
      newest text it was sent. A line containing [ERROR] is an error and one containing
      [TODO] a warning.
    - a build check, like dune: {!Config.build_delay} after a save (and when a session
      starts, like a watch's first build) it checks the saved text: [ERROR] lines are
      errors, and there is a warning in a file that is not open ({!other_file}).

    Whenever either check finishes, the open file's list is sent again with both
    checks' newest findings, versioned with the revision of the edit check it includes
    (none before the first). The other file's list is unversioned.

    [Kill] stops the source as a crash would; [Restart] starts a new session, which
    forgets the old results and runs both checks again. There is no automatic restart
    (phase 10). *)
open! Core
open! Async

module Config : sig
  type t =
    { edit_delay : Time_ns.Span.t
    ; build_delay : Time_ns.Span.t
    }

  (** 400 ms and 800 ms: slow enough to see findings dim while behind the text. *)
  val default : t
end

val source : string

(** The not-open file the build source reports on, beside [resource]. *)
val other_file : resource:string -> string

(** Starts the source for the workspace [root], reporting [Started]. *)
val start
  :  ?config:Config.t
  -> ?time_source:Time_source.t
  -> root:string
  -> unit
  -> Source.t

(** The edit check's findings for [text]. *)
val edit_findings : string -> Ches_error.Error.Diagnostics.Finding.t list

(** The build check's findings for [text] (only the open file's part). *)
val build_findings : string -> Ches_error.Error.Diagnostics.Finding.t list

(** Scripted producers, for tests and measurements: play events at given times
    regardless of requests, to make bursts, out-of-order revisions, and crashes
    happen exactly. *)
module Script : sig
  type step =
    | Wait of Time_ns.Span.t
    | Emit of Ches_error.Source_event.t

  (** Plays [steps] in order, starting at once. Requests are ignored. *)
  val play : ?time_source:Time_source.t -> step list -> Source.t

  (** [snapshots] versioned snapshots of [findings] findings each, spread over
      [resources] files (["burst-<i>.ml"]) round robin, with increasing revisions. *)
  val burst
    :  source:string
    -> snapshots:int
    -> resources:int
    -> findings:int
    -> Ches_error.Source_event.t list
end
