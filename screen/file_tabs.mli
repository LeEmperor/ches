(** A deterministic contiguous window around the active tab. [<] / [>] indicate
    hidden neighbors. Even a one-cell strip retains the active style. [*] marks
    modified files; [!] marks missing files. Data comes from Open_buffers. *)
val render : Ches_app.Open_buffers.t list -> width:int -> Span.t list

(** {!render} for the whole tab strip: file and view tabs ({!Tab_strip.Item}). *)
val render_items : Tab_strip.Item.t list -> width:int -> Span.t list
