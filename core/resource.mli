(** Lexical absolute normalization only: never resolves symlinks. *)
val normalize : cwd:string -> string -> string
