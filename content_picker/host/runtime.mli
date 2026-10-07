open! Core
open! Async
type t
(** Single Async-scheduler owner. Reuse one provider. Opening preflights the shared
    float before replacing discovery. Production activation/acceptance is owned by
    Editor_view and Ui_state, not this provider runtime.
    Closing callbacks are session-generation-specific, not query-run-specific. *)
val create : ?prog:string -> ?limits:Ches_content_search.Provider.Limits.t -> unit -> t
val open_picker : t -> Ches_screen.Ui_state.t -> root:string -> width:int -> height:int
  -> Ches_screen.Ui_state.t Or_error.t
val needs_turn : t -> Ches_screen.Ui_state.t -> bool
val next : t -> Ches_screen.Ui_state.t -> Ches_screen.Ui_state.Input.t list Deferred.t
(** One 2ms yielded poll, at most one provider batch. Query changes start a fresh
    request (provider owns debounce/cancel/reap). Awaited obsolete turns return no
    events; installations additionally validate exact run/root/query identity.
    Chain turns with current UI, not one per redraw; only one caller may poll. *)
val pump : t -> current:(unit -> Ches_screen.Ui_state.t)
  -> inject:(Ches_screen.Ui_state.Input.t list -> unit Deferred.t) -> unit Deferred.t
val cancel : t -> unit
val finished : t -> unit Deferred.t
(** Cleanup/reaping of latest run and all preceding replacements, not notification
    that terminal snapshots have been consumed. *)
