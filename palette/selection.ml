open! Core

let preserve selected results ~id ~equal =
  match selected with
  | Some selected when List.exists results ~f:(fun result -> equal selected (id result)) ->
    Some selected
  | _ -> Option.map (List.hd results) ~f:id
;;
