open! Core

type configuration = (Ches_config_runtime.Settings.t, string) Result.t
type t

(** Loader injection is per instance. Production uses [Loader.load ()], including
    its path resolution, defaults, bounded child lifetime and cleanup. *)
val create : ?load:(unit -> configuration Async.Deferred.t) -> unit -> t

(** Await before mounting the interactive app; uses the same loader as reload. *)
val startup : t -> configuration Async.Deferred.t

(** At most one active reload and one replaceable latest pending generation.
    Obsolete results are discarded before delivery and guarded again by screen. *)
val submit : t -> int list -> unit
val next : t -> (int * configuration) option Async.Deferred.t

(** Clears pending/replies and wakes readers. Inflight bounded loader work may
    finish and clean up its children, but cannot publish or launch pending work. *)
val stop : t -> unit

(** Stops delivery immediately, then waits for the bounded loader to finish child
    cleanup. Production awaits this after restoring the terminal and at shutdown. *)
val shutdown : t -> unit Async.Deferred.t
