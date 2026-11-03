(** Absolute, nonempty XDG_CONFIG_HOME takes precedence over HOME/.config.
    Returns [None] when neither provides a usable configuration location. *)
val config_path : getenv:(string -> string option) -> string option

(** Each explicit load executes a fresh standalone OCaml program, reusing a
    validated compiled helper when available.
    Missing configuration means defaults; all other failures are diagnostics.
    User code is executable OCaml, not sandboxed. *)
val load : ?path:string -> unit -> (Settings.t, string) Result.t Async.Deferred.t

(** Local dependency injection for tests; never mutates the process environment.
    Caching is disabled unless [cache_dir] is explicitly supplied. *)
module For_testing : sig
  val cache_path : getenv:(string -> string option) -> string option
  val decode : string -> Settings.t Core.Or_error.t
  val load
     :  ?path:string
    -> ?cache_dir:string
    -> ?api_source:string
    -> ?getenv:(string -> string option)
    -> ?compiler:string
    -> ?compile_timeout:float
    -> ?runtime_timeout:float
    -> unit
    -> (Settings.t, string) Result.t Async.Deferred.t
end
