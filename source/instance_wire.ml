open! Core
open Ches_error.Language_query
let field = Completion_wire.field
let string_field = Completion_wire.string_field

let instance encoding json =
  match string_field json "instPath" with
  | Some hier_path when not (String.is_empty hier_path) && String.length hier_path <= 16384 ->
    let target = Option.bind (field json "instLoc") ~f:(fun loc ->
      match Navigation_wire.locations encoding loc with
      | Ok [target] -> Some target | _ -> None) in
    Ok { hier_path; target }
  | _ -> Error "Invalid instance hierarchy path"

let instances encoding = function
  | `List xs when List.length xs <= 256 -> Result.all (List.map xs ~f:(instance encoding))
  | _ -> Error "Invalid or oversized instance list"

(* Only enclosing server ranges are eligible. Flat SymbolInformation is accepted
   only when its location belongs to the queried document, never an included file. *)
let modules ~uri ~position json =
  let budget = ref 4096 in
  let oversized = ref false in
  let rec walk depth in_module json =
    decr budget;
    if depth > 64 || !budget < 0 then (oversized := true; []) else
    match json with
    | `List xs when List.length xs <= 4096 -> List.concat_map xs ~f:(walk (depth + 1) in_module)
    | `Assoc _ ->
      let location = Option.value (field json "location") ~default:`Null in
      let own = match string_field location "uri" with None -> true | Some other -> String.equal uri other in
      let range = Option.first_some (field json "range") (field location "range") in
      let module_symbol = match Completion_wire.int_field json "kind" with
        | Some (2 | 11) -> true | _ -> false in
      let here = match own && not in_module, module_symbol, string_field json "name", range with
        | true, true, Some name, Some r when not (String.is_empty name) && String.length name <= 16384 -> (match Navigation_wire.range r with
          | Ok r when Navigation_wire.compare_point r.start position <= 0
              && Navigation_wire.compare_point position r.stop < 0 -> [name, r]
          | _ -> [])
        | _ -> [] in
      (* Slang also uses Module for nested instantiation declarations. Their
         names/ranges do not identify the containing module definition. *)
      if not own then [] else
      here @ walk (depth + 1) (in_module || module_symbol)
        (Option.value (field json "children") ~default:`Null)
    | _ -> [] in
  let candidates = walk 0 false json in
  (if !oversized then [] else candidates)
  |> List.sort ~compare:(fun (_, a) (_, b) ->
    let c = Navigation_wire.compare_point b.start a.start in
    if c <> 0 then c else Navigation_wire.compare_point a.stop b.stop)
