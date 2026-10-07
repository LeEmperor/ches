(** Passive, cell-exact vertical buffer rows. The visible window follows the active
    buffer; no independent selection, scroll or lifetime state is retained. *)
val render : Ches_app.Open_buffers.t list -> width:int -> rows:int -> Span.t list list
