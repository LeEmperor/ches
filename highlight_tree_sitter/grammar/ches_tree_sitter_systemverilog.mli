(** The statically linked, pinned SystemVerilog grammar. Its address remains valid
    for the lifetime of the process. *)
val language : unit -> Tree_sitter.Language.t
