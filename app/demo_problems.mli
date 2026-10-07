(** Seed eight acknowledged, explicitly labelled, session-local synthetic problems
    with valid column-1 locations spread over the current file's lines. Does not
    edit, load, save, or resolve real problems. Unnamed documents are unchanged.
    Reinstalling updates the same demo identities instead of duplicating them.
    Locations are a startup snapshot, not refreshed after editing/reloading. *)
val install : Controller.t -> Controller.t
