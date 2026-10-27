(** Lexical absolute normalization only: never resolves symlinks. *)
val normalize : cwd:string -> string -> string

(** [path] is [root] or lies under it, comparing path components lexically (both
    absolute and normalized; symlinks are not resolved): ["/a/b"] is within ["/a/b"],
    ["/a"] and ["/"]; ["/a/bc"] is not within ["/a/b"]. *)
val within : root:string -> string -> bool
