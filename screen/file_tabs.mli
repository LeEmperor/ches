(** A deterministic contiguous window around the active tab. [<] / [>] indicate
    hidden neighbors. Even a one-cell strip retains the active style. [*] marks
    modified files; [!] marks missing files. Data comes from Open_buffers. *)
val render : Ches_app.Open_buffers.t list -> width:int -> Span.t list
