(** One-line descriptions of steps that did not succeed, for errors, snapshot problems and
    the command log: the command line ({!Ches_vcs.Exec.Spec.to_string_hum}), its status
    ({!Ches_vcs.Exec.Result.status_hum}) and its stripped stderr, e.g.
    ["git --no-pager ... log ...: exit 128: fatal: bad revision 'HEAD'"]. *)

open! Core
open Ches_vcs

val of_result : Exec.Spec.t -> Exec.Result.t -> string

(** Any step report: a command as {!of_result}; a file read as ["<path>: <error>"]; a
    skipped step as ["<command or path>: skipped"]. *)
val of_report : Job.Step_report.t -> string
