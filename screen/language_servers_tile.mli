(** Live read-only process inventory supplied by the source manager. Diagnostic
    feedback is deliberately not used to infer server readiness or attachments. *)
open! Core

type t [@@deriving sexp_of]

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
val create : source_attached:bool -> t
val inventory : t -> Ches_error.Source_event.Server.t list -> t
(** Replace the authoritative snapshot, retaining the text cursor and clearing a
    selection only when the report's text changes. *)
val context : t -> string option -> t
(** The active file context, independent of focus on the report tab. *)
val key : t Type_equal.Id.t
val adapter : (t, Ches_tile.Text_view.Action.t) View_registry.Adapter.t
