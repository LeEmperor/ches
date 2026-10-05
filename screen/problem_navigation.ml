open! Core
module Feedback = Ches_error.Error

type t =
  { selected : Feedback.Identity.t option
  ; index : int
  ; top : int
  }
[@@deriving sexp_of]

let empty = { selected = None; index = 0; top = 0 }

let fit t problems ~rows =
  let count = List.length problems in
  let index =
    Option.bind t.selected ~f:(fun identity ->
      List.findi problems ~f:(fun _ p -> Feedback.Identity.equal p.Feedback.Problem.identity identity)
      |> Option.map ~f:fst)
    |> Option.value ~default:(Int.min t.index (Int.max 0 (count - 1)))
  in
  let selected = Option.map (List.nth problems index) ~f:(fun p -> p.Feedback.Problem.identity) in
  let rows = Int.max 1 rows in
  let top = Int.min t.top (Int.max 0 (count - rows)) in
  let top = if index < top then index else if index >= top + rows then index - rows + 1 else top in
  { selected; index; top }
;;

let select t problems ~rows index =
  let index = Int.clamp_exn index ~min:0 ~max:(Int.max 0 (List.length problems - 1)) in
  fit { t with selected = None; index } problems ~rows
;;
