open! Core
module Source_event = Ches_error.Source_event

type t =
  { newest_first : Source_event.t list
  ; dropped : int
  }
[@@deriving sexp_of]

let empty = { newest_first = []; dropped = 0 }

let rec classify (event : Source_event.t) =
  match event with
  | Owned { resource; generation; event } ->
    let kind, source, target = classify event in
    kind, sprintf "%s:%d:%s" resource generation source, target
  | Diagnostics { source; resource; _ } -> `Diagnostics, source, resource
  | Started { source; _ } | Stopped { source; _ } | Unavailable { source; _ } -> `Lifecycle, source, ""
;;

(* The pending snapshot for [source, resource], if no lifecycle event of [source] came
   after it, removed. *)
let rec remove_replaceable events ~source ~resource =
  match events with
  | [] -> None
  | (event : Source_event.t) :: rest ->
    (match classify event with
     | `Diagnostics, s, r when String.equal s source && String.equal r resource
        -> Some rest
     | `Lifecycle, s, _ when String.equal s source -> None
     | _ ->
       Option.map (remove_replaceable rest ~source ~resource) ~f:(fun rest -> event :: rest))
;;

let push t (event : Source_event.t) =
  match classify event with
  | `Lifecycle, _, _ -> { t with newest_first = event :: t.newest_first }
  | `Diagnostics, source, resource ->
    (match remove_replaceable t.newest_first ~source ~resource with
     | None -> { t with newest_first = event :: t.newest_first }
     | Some rest -> { newest_first = event :: rest; dropped = t.dropped + 1 })
;;

let take t ~max =
  let oldest_first = List.rev t.newest_first in
  let taken = List.take oldest_first max
  and rest = List.drop oldest_first max in
  { t with newest_first = List.rev rest }, taken
;;

let length t = List.length t.newest_first
let dropped t = t.dropped
