open! Core
open! Async
module Model = Ches_navigation_preview_model.Model
type t
(** Late, bounded retained lookup. Every [Some] state is authoritative. *)
val create : ?debounce:Time_ns.Span.t -> ?timeout:Time_ns.Span.t
  -> buffer:(Model.request -> Model.state option) -> unit -> t
val follow : t -> Model.request option -> unit
val snapshot : t -> Model.snapshot option
val changed : t -> unit Deferred.t
val clear : t -> unit
(** Cancels immediately without waiting for physical disk reads. *)
val stop : t -> unit
val finished : t -> unit Deferred.t
module For_testing : sig
  val create : ?debounce:Time_ns.Span.t -> ?timeout:Time_ns.Span.t
    -> buffer:(Model.request -> Model.state option)
    -> read:(cancelled:bool Atomic.t -> Model.request -> Model.state Deferred.t)
    -> unit -> t
  val disk_read : cancelled:bool Atomic.t -> Model.request -> Model.state Deferred.t
end
