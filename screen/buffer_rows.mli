(** Passive, cell-exact vertical buffer rows. The visible window follows the active
    buffer; no independent selection, scroll or lifetime state is retained. *)
val render : Ches_app.Open_buffers.t list -> width:int -> rows:int -> Span.t list list

(** {!render} for the whole tab strip: file and view tabs ({!Tab_strip.Item}). *)
val render_items : Tab_strip.Item.t list -> width:int -> rows:int -> Span.t list list
