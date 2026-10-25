(** Compose status metadata and optional passive tab-strip rows (file and view tabs)
    for a tile's content rectangle. An empty list retains the existing status-only
    presentation.
    Session/controller lifetimes remain outside this renderer. *)
val body
  :  rect:Geometry.Rect.t
  -> Status_field.t list
  -> Tab_strip.Item.t list
  -> Span.t list list
