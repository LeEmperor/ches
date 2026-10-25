open! Core
open Ches_input

type t =
  { name : string
  ; keys : Key.t list
  ; description : string
  }
[@@deriving sexp_of, equal]

let create name ~keys description = { name; keys; description }

let valid_name name =
  (not (String.is_empty name))
  && String.for_all name ~f:(fun c ->
    Char.is_lowercase c || Char.is_digit c || Char.equal c '.' || Char.equal c '-')
;;

let keys_hum t = List.map t.keys ~f:Key.to_string_hum |> String.concat ~sep:" "
