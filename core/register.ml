open! Core

module Kind = struct
  type t =
    | Characterwise
    | Linewise
  [@@deriving sexp_of, equal]
end

type t =
  | Protected_block of
      { rows : string list
      ; width : int
      }
  | Protected_text of
      { text : string
      ; kind : Kind.t
      ; scope : string
      ; identities : (int * string) list
      }
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
   | Protected_text { text; kind = Characterwise; _ } | Text { text; kind = Characterwise } -> text
  (* The last line of a file without a final newline yanks without one; on the
     clipboard every line ends with one, as in Vim. *)
   | Protected_text { text; kind = Linewise; _ } | Text { text; kind = Linewise } ->
    if String.is_suffix text ~suffix:"\n" then text else text ^ "\n"
   | Protected_block { rows; width = _ } | Block { rows; width = _ } -> String.concat ~sep:"\n" rows
;;
