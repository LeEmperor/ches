(** Seed static, explicitly labelled, synthetic diagnostic findings for manual review of
    the problems view before a real source exists: two live sources on the current
    file (one versioned at the current revision, one unversioned, with a Hint), a finding
    in another file, and a stopped source whose finding stays marked; its stop warning is
    already dismissed, but recorded in history.
    Nothing ever updates them, so edits leave current-file findings dimmed. Does not edit,
    load, or save. Unnamed documents are unchanged. *)
val install : Controller.t -> Controller.t
