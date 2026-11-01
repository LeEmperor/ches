open! Core

(** Pure, immutable semantic palettes, shared by every presentation. *)
module Role : sig
  type t =
    | Backdrop | Background | Foreground | Surface | Muted | Border | Current_line
    | Normal_accent | Insert_accent | Special | Warning | Error
    | Block_cursor | Block_copy | Smear
    | Syntax_keyword | Syntax_string | Syntax_number | Syntax_comment
    | Syntax_type | Syntax_function | Syntax_module | Syntax_constant
    | Selection_foreground | Selection_background
    | Search_foreground | Search_background
    | Search_current_foreground | Search_current_background
    | Diff_added | Diff_removed | Diff_hunk
  [@@deriving sexp_of, equal, enumerate]
end

type rgb = int * int * int

module Kind : sig
  type t = Dark | Light [@@deriving sexp_of, equal]
end

type t [@@deriving sexp_of, equal]

val id : t -> string
val title : t -> string
val kind : t -> Kind.t
val color : t -> Role.t -> rgb

(** Base16 slots 00..07 are the ground-to-foreground ramp; 08..0f are
    red, orange, yellow, green, cyan, blue, violet, and brown accents.
    Copies the palette; raises [Invalid_argument] for invalid length/channels
    or an empty/noncanonical ID. IDs use lowercase ASCII letters, digits and hyphens. *)
val of_base16 : id:string -> title:string -> kind:Kind.t -> palette:rgb array -> t

(** Stable IDs; lookup ignores case, surrounding whitespace, and treats spaces
    and underscores as hyphens. The four original presets lead the registry.
    Additional names describe curated palettes or inspired adaptations, not exact
    upstream ports. *)
val all : t list
val default : t
val find : string -> t option
