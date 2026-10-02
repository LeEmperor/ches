open! Core

type t =
  | Off
  | Absolute
  | Relative
  | Hybrid
[@@deriving sexp_of, equal, enumerate]

let switches = function
  | Off -> false, false
  | Absolute -> true, false
  | Relative -> false, true
  | Hybrid -> true, true
;;

let of_switches ~absolute ~relative =
  match absolute, relative with
  | false, false -> Off
  | true, false -> Absolute
  | false, true -> Relative
  | true, true -> Hybrid
;;

let toggle_absolute t =
  let absolute, relative = switches t in
  of_switches ~absolute:(not absolute) ~relative
;;

let toggle_relative t =
  let absolute, relative = switches t in
  of_switches ~absolute ~relative:(not relative)
;;

let to_string = function
  | Off -> "off"
  | Absolute -> "absolute"
  | Relative -> "relative"
  | Hybrid -> "hybrid"
;;

let label t ~digits ~line ~cursor_line =
  let distance = Int.abs (line - cursor_line) in
  match t with
  | Off -> String.make (digits + 1) ' '
  | Absolute -> sprintf "%*d " digits (line + 1)
  | Relative -> sprintf "%*d " digits distance
  | Hybrid ->
    if line = cursor_line
    then sprintf "%-*d " digits (line + 1)
    else sprintf "%*d " digits distance
;;
