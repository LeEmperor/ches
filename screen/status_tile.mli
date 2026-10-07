(** Compose status metadata and optional passive buffer rows for a tile's content
    rectangle. An empty buffer list retains the existing status-only presentation.
    Session/controller lifetimes remain outside this renderer. *)
val body
  :  rect:Geometry.Rect.t
  -> Status_field.t list
  -> Ches_app.Open_buffers.t list
  -> Span.t list list
