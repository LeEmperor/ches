open! Core
open Ches_core

(* Local reverse-component trie. Counts include terminal paths, preserving the
   old rule that a full path is allowed even when it is another path's suffix. *)
type node = { mutable count : int; children : node String.Table.t }
let node () = { count = 0; children = String.Table.create () }

let create files =
  let root = node () in
  let paths = List.map files ~f:(fun (id, path) ->
    let parts = Option.value_map path ~default:[ "[unnamed]" ] ~f:(fun path ->
      String.split path ~on:'/' |> List.filter ~f:(Fn.non String.is_empty)) in
    id, List.rev parts) in
  List.iter paths ~f:(fun (_, parts) ->
    ignore (List.fold parts ~init:root ~f:(fun parent part ->
      let child = Hashtbl.find_or_add parent.children part ~default:node in
      child.count <- child.count + 1;
      child) : node));
  List.map paths ~f:(fun (id, parts) ->
    let rec select parent selected = function
      | [] -> selected
      | part :: rest ->
        let child = Hashtbl.find_exn parent.children part in
        let selected = part :: selected in
        if child.count = 1 then selected else select child selected rest in
    id, String.concat ~sep:"/" (List.map (select root [] parts) ~f:Directory_identity.encode_name))
;;
