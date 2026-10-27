(** The rules every git command Ches runs follows, as spec builders. Every other module
    of this library builds its specs here; none passes text through a shell.

    Every spec runs [git] (looked up on [PATH]) with {!prefix} before the subcommand,
    stdin [Null] unless stated, and the default timeouts and limits of
    {!Ches_vcs.Exec.Spec.create} unless stated. Subcommand rules, applied by the
    modules that build each command:
    - NUL-separated output wherever git offers it ([-z], [%x00] in formats).
    - Diff-producing commands pass [--no-color] and [--no-ext-diff] explicitly (a
      user's [color.diff=always] overrides [color.ui]), plus [--no-relative],
      [--src-prefix=a/ --dst-prefix=b/] (against [diff.noprefix] and
      [diff.mnemonicPrefix]) and [--find-renames].
    - Log-like commands pass an explicit [--format] and [--no-show-signature].
    - User-supplied text (paths, branch names, messages) is never parsed as an
      option: paths follow [--]; refs and revisions follow [--end-of-options] or are
      validated by the caller first. *)

open! Core
open Ches_vcs

(** [--no-pager -c color.ui=false -c core.quotepath=false]. *)
val prefix : string list

(** Extra environment of every read: [GIT_OPTIONAL_LOCKS=0] (a read never takes
    [index.lock] to refresh stat data, so it cannot make a concurrent mutation fail)
    and [LC_ALL=C] (git's human-readable fields that parsers rely on, such as
    [for-each-ref]'s [%(upstream:track)] and fatal messages, are untranslated).
    Mutations and network commands inherit the user's locale. *)
val read_env : (string * string) list

(** [git prefix args] as a [Read] in [cwd], with {!read_env}. *)
val read : ?stdout_limit:int -> cwd:string -> string list -> Exec.Spec.t

(** [git prefix args] as a [Mutate] in [cwd], no extra environment. *)
val mutate : ?stdin:Exec.Stdin.t -> cwd:string -> string list -> Exec.Spec.t

(** [git prefix args] as a [Network] in [cwd], streaming its output (progress).
    Authentication environment is added by the runner, not here
    ([Ches_vcs_host.Auth]). *)
val network : cwd:string -> string list -> Exec.Spec.t
