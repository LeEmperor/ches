(** The non-interactive environment every child runs with (plan: "Authentication
    constraints"). Ches owns the terminal, so no child may prompt on it: git's own
    credential prompt and editor are disabled, and ssh, which opens [/dev/tty] itself for
    passphrases and host keys, runs in batch mode unless the user chose their own ssh
    command. Credentials come from ssh-agent or a credential helper.

    Git-specific, like the only network backend so far. A later backend with its own
    transport (Mercurial's [ui.ssh]) generalizes this module. *)

open! Core
open Ches_vcs

(** ["ssh -o BatchMode=yes"] *)
val batch_ssh_command : string

(** The complete environment for a child, given [base] (the runner's inherited
    environment overlaid with the spec's [env], later bindings winning):
    - every kind: [GIT_TERMINAL_PROMPT=0] and (phase 7) [GIT_EDITOR=true], replacing
      any binding in [base]: no child may start an editor on the terminal either
      (git would for [rebase --continue] or a merge without [--no-edit]; [true]
      keeps the prepared message as it is);
    - [Network]: also [GIT_SSH_COMMAND=]{!batch_ssh_command}, unless [base] binds
      [GIT_SSH_COMMAND] or [GIT_SSH] to a non-empty value or [ssh_command_configured]
      (the user chose their own ssh, which then must not prompt on the terminal).
    Each name appears once in the result. *)
val environment
  :  kind:Exec.Kind.t
  -> base:(string * string) list
  -> ssh_command_configured:bool
  -> (string * string) list

(** The probe the runner runs (without events, with environment [base] and
    [GIT_TERMINAL_PROMPT=0]) in a network step's cwd before starting it:
    [git --no-pager config --get core.sshCommand], a [Read] with a 10-second
    timeout. *)
val ssh_command_probe : cwd:string -> Exec.Spec.t

(** From the probe's result: exit 0 with non-blank stdout is configured; anything
    else is not, including a failed probe (so batch mode is added: a refused key is
    reported in the log, while a prompt would corrupt the screen). *)
val ssh_command_configured : Exec.Result.t -> bool
