open! Core

(** Linux no-replace renames, exclusive creates. All rename sources are staged
    before final placement. Failure returns reconciled backing names (including
    owned staging names) and unresolved text, so ordinary save safely retries.
    [before_mutation] is an isolated-fixture fault/race injection seam. *)
type result =
  { buffer : Directory_buffer.t
  ; moves : (string * string) list
  ; completed : int
  ; error : Error.t option
  }
val apply : ?reserved_paths:string list -> ?before_mutation:(int -> unit) -> Directory_buffer.t -> result
