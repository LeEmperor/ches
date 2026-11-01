open! Core

type t = Workspace | Zen | Bare [@@deriving sexp_of, equal]

module Bare_prefs = struct
  type t = { line_numbers : Line_numbers.t } [@@deriving sexp_of, equal]

  let default = { line_numbers = Line_numbers.Off }
end

let suppress_workspace = function
  | Workspace -> false
  | Zen | Bare -> true
;;
