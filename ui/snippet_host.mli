open! Core

type catalog = (Ches_completion.User_snippets.t, string) Result.t
type t

(** Absolute nonempty XDG_CONFIG_HOME takes precedence; otherwise HOME/.config.
    No filesystem changes are made. Missing HOME is an error when needed. *)
val config_path : getenv:(string -> string option) -> string Or_error.t

(** One worker and at most one pending (latest) generation. Reads and parsing run
    on a worker thread, never on the editor's Async scheduler. *)
val create : unit -> t
val submit : t -> int list -> unit
val next : t -> (int * catalog) option Async.Deferred.t
val stop : t -> unit

module For_testing : sig
  val load : path:string -> catalog Async.Deferred.t
  val create : load:(unit -> catalog Async.Deferred.t) -> t
end
