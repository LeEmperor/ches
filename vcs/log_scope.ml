open! Core

module Range = struct
  type t =
    | Head
    | Branch of string
    | All
  [@@deriving sexp, equal]
end

type t =
  { range : Range.t
  ; path : string option
  ; graph : bool
  ; merges : bool
  ; first_parent : bool
  ; limit : int
  }
[@@deriving sexp, equal]

let default_limit = 200
let max_limit = 12800

let default =
  { range = Head
  ; path = None
  ; graph = true
  ; merges = true
  ; first_parent = false
  ; limit = default_limit
  }
;;

let more t =
  if t.limit >= max_limit then None else Some { t with limit = min (t.limit * 2) max_limit }
;;

let graph_shown t = t.graph && Option.is_none t.path && t.merges

let title t ~shown =
  let base =
    match t.path, t.range with
    | Some path, _ -> "History of " ^ path
    | None, Head -> "Recent commits"
    | None, Branch branch -> "Commits on " ^ branch
    | None, All -> "All branches"
  in
  let qualifiers =
    List.filter_opt
      [ Option.some_if (not t.merges) "no merges"
      ; Option.some_if t.first_parent "first parent"
      ; Option.some_if (shown >= t.limit) (sprintf "first %d" t.limit)
      ]
  in
  match qualifiers with
  | [] -> base
  | _ -> sprintf "%s (%s)" base (String.concat qualifiers ~sep:", ")
;;
