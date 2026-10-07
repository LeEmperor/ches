(** Where a diagnostic source is started for a document. *)
open! Core

(** The root for [path] by Neovim's [vim.fs.root] rule: each marker in [markers] in turn
    is looked for in [path]'s directory and then each ancestor's, and the first marker
    found anywhere wins, at its nearest directory. Markers are literal file or directory
    names (as in Neovim, ["*.opam"] matches only that name). The result is absolute;
    [path]'s directory itself when no marker is found or it cannot be resolved. *)
val find_first : markers:string list -> string -> string

(** [find_first ~markers:["dune-project"]]: the synthetic checker's root. *)
val find : string -> string
