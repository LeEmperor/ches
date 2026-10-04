open! Core

module Kind = struct
  type t =
    | Characterwise
    | Linewise
  [@@deriving sexp_of, equal]
end

type t =
  | Text of
      { text : string
      ; kind : Kind.t
      }
  | Block of
      { rows : string list
      ; width : int
      }
[@@deriving sexp_of, equal]

let to_string = function
  | Text { text; kind = Characterwise } -> text
  (* The last line of a file without a final newline yanks without one; on the
     clipboard every line ends with one, as in Vim. *)
  | Text { text; kind = Linewise } ->
    if String.is_suffix text ~suffix:"\n" then text else text ^ "\n"
  | Block { rows; width = _ } -> String.concat ~sep:"\n" rows
;;
