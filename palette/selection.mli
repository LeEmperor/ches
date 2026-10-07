open! Core

(** Keep selection by identity across filtering/reordering; if it disappears, use
    the first result, or none. This is separate from viewport scrolling. *)
val preserve : 'id option -> 'result list -> id:('result -> 'id) -> equal:('id -> 'id -> bool) -> 'id option
