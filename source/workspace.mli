(** Separate single-document runtimes, lifetime-tagged events. *)
val start : create:(string -> Source.t option) -> unit -> Source.t
