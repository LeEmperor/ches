open! Core
open! Async
type t
(** One reusable service per frontend. [buffer] is called on the Async scheduler
    AFTER debounce and must return a bounded snapshot (use Buffer_snapshot.lookup
    against the current app session). None falls back to disk. *)
val create
  : ?debounce:Time_ns.Span.t -> ?timeout:Time_ns.Span.t
  -> buffer:(path:string -> Model.state option) -> unit -> t
(** Idempotent for the same session/selected identity, unless [refresh=true]
    (use on a known retained-buffer revision change, not every render).
    Fresh generation on every replacement, including A->B->A.
    None/close/deactivation must call [clear]. *)
val select
  : ?refresh:bool -> t -> session:Ches_file_picker.Model.Discovery.request
  -> Ches_file_picker.Model.Candidate.t -> Model.request
(** Host assembly seam: follow the pure picker's selected identity and discovery
    session, or clear on inactive/empty selection. Pass None for a closed picker,
    exited UI or deactivated frontend even if an old picker model remains alive.
    Returns the exact expected token for [Model.accept] at UI installation. *)
val follow : ?refresh:bool -> t -> _ Ches_file_picker.Model.t option -> Model.request option
val snapshot : t -> Model.snapshot option
(** Wait for the next state/selection/clear notification. A single frontend-owned
    pump should capture this waiter before reading/injecting a snapshot, then await
    it, so changes during injection are not lost. It must also observe selection
    synchronously and clear explicitly on teardown. *)
val changed : t -> unit Deferred.t
(** Drops payload/pending work immediately, aborts timers and requests cooperative
    read cancellation. Always wakes [changed], even when already empty, so a
    frontend teardown can release its waiting pump. *)
val clear : t -> unit
(** Completion of the physical read active at call time, NOT needed for UI close.
    Call [clear] first when joining teardown in tests/background cleanup. A stalled
    filesystem may delay this; replacement never starts another read until it
    finishes. *)
val finished : t -> unit Deferred.t
module For_testing : sig
  val create
    : ?debounce:Time_ns.Span.t -> ?timeout:Time_ns.Span.t
    -> buffer:(path:string -> Model.state option)
    -> read:(cancelled:bool Atomic.t -> path:string -> Model.state option Deferred.t)
    -> unit -> t
end
