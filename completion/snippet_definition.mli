(** Shared source definition for bundled snippet catalogs. Collection describes
    purpose independently of the stable ID and language/file scopes. *)
type t =
  { id : string
  ; prefix : string
  ; scopes : string list
  ; collection : string
  ; description : string
  ; body : string
  }
