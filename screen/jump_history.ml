open! Core

type location = { path : string; offset : int } [@@deriving sexp_of, equal]
type t = { back : location list; forward : location list } [@@deriving sexp_of]
let empty = { back = []; forward = [] }

let push locations location =
  match locations with
  | head :: _ when equal_location head location -> locations
  | _ -> List.take (location :: locations) 128
;;

let record t ~origin ~destination =
  if equal_location origin destination then t
  else { back = push t.back origin; forward = [] }
;;

let traverse source reverse ~current =
  match List.drop_while source ~f:(equal_location current) with
  | [] -> None
  | destination :: rest -> Some (destination, rest, push reverse current)
;;

let peek_back t ~current =
  Option.map (traverse t.back t.forward ~current) ~f:(fun (location, back, forward) ->
    location, { back; forward })
;;

let peek_forward t ~current =
  Option.map (traverse t.forward t.back ~current) ~f:(fun (location, forward, back) ->
    location, { back; forward })
;;
