open! Core

type t =
  | Plain
  | Keyword
  | String
  | Escape
  | Number
  | Comment
  | Type
  | Constructor
  | Module
  | Function
  | Variable
  | Property
  | Operator
  | Punctuation
  | Constant
[@@deriving sexp_of, equal, compare, enumerate]

let priority = function
  | Escape -> 0 | Comment -> 1 | String -> 2 | Keyword -> 3
  | Function -> 4 | Type -> 5 | Constructor -> 6 | Module -> 7
  | Property -> 8 | Constant -> 9 | Number -> 10 | Operator -> 11
  | Punctuation -> 12 | Variable -> 13 | Plain -> 14
;;

let of_capture name =
  match String.lsplit2 name ~on:'.' |> Option.value_map ~default:name ~f:fst with
  | "keyword" -> Some Keyword
  | "string" -> Some String
  | "escape" -> Some Escape
  | "number" -> Some Number
  | "comment" -> Some Comment
  | "type" -> Some Type
  | "constructor" -> Some Constructor
  | "module" -> Some Module
  | "function" -> Some Function
  | "variable" -> Some Variable
  | "property" | "tag" -> Some Property
  | "operator" -> Some Operator
  | "punctuation" -> Some Punctuation
  | "constant" -> Some Constant
  | _ -> None
;;
