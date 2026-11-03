(** Absolute, nonempty XDG_CONFIG_HOME takes precedence over HOME/.config.
    Returns [None] when neither provides a usable configuration location. *)
val config_path : getenv:(string -> string option) -> string option

(** Each explicit load compiles and executes a fresh standalone OCaml program.
    Missing configuration means defaults; all other failures are diagnostics.
    User code is executable OCaml, not sandboxed. *)
val load : ?path:string -> unit -> (Settings.t, string) Result.t Async.Deferred.t

(** Local dependency injection for tests; never mutates the process environment. *)
module For_testing : sig
  val load
    :  ?path:string
    -> ?getenv:(string -> string option)
    -> ?compiler:string
    -> ?compile_timeout:float
    -> ?runtime_timeout:float
    -> unit
    -> (Settings.t, string) Result.t Async.Deferred.t
end
