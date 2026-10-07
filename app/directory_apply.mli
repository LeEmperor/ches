open! Core

(** Linux no-replace renames, exclusive creates/copies, permanent unlink/empty
    rmdir. Recursive copies do not follow symlinks and preserve rwx bits only.
    Cross-device moves are explicitly unsupported; copies may cross devices.
    All rename sources are staged
    before final placement. Failure returns reconciled backing names (including
    owned staging names) and unresolved text, so ordinary save safely retries.
    [before_mutation] and [before_copy_publish] are isolated-fixture fault/race
    injection seams. Copies publish private destination-side trees exclusively.
    Publication rechecks parent identity. Cleanup refuses a replaced private root;
    external parent relocation may leave the owned private tree behind. *)
type result =
  { buffer : Directory_buffer.t
  ; moves : (string * string) list
  ; deleted : string list
  ; affected : string list
  ; completed : int
  ; applied : Ches_core.Directory_plan.operation list
  (** Completed syscalls in order, including staging renames. [moves] instead
      maps each original backing resource directly to its current actual path. *)
  ; error : Error.t option
  }
val apply : ?reserved_paths:string list -> ?before_mutation:(int -> unit)
  -> ?before_copy_publish:(string -> unit) -> Directory_buffer.t -> result
module For_testing : sig
  (** Exercise the syscall's own no-overwrite guarantee in isolated fixtures. *)
  val rename_noreplace : string -> string -> unit
end
