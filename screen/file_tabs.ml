open! Core
open Ches_app
open Ches_core

type tab =
  { id : Buffer_id.t
  ; label : string
  ; active : bool
  ; modified : bool
  }
[@@deriving sexp_of]

let tabs session =
  let files = Session.buffers session in
  let parts c = Option.value_map (Editor.path (Controller.editor c))
    ~default:[ "[unnamed]" ] ~f:(fun p -> String.split p ~on:'/' |> List.filter ~f:(Fn.non String.is_empty)) in
  let suffix parts n = List.drop parts (Int.max 0 (List.length parts - n)) in
  List.map files ~f:(fun (id, c) ->
    let path = parts c in
    let rec label n =
      let candidate = suffix path n in
      if n < List.length path && List.exists files ~f:(fun (other, c) ->
        not (Buffer_id.equal id other) && [%equal: string list] candidate (suffix (parts c) n))
      then label (n + 1)
      else String.concat ~sep:"/" (List.map candidate ~f:Directory_identity.encode_name)
    in
    { id; label = label 1 ^ (if Controller.is_missing c then " [missing]" else "")
    ; active = Option.equal Buffer_id.equal (Some id) (Session.active_id session)
    ; modified = Editor.is_dirty (Controller.editor c) })
;;

let render tabs ~width =
  let width = Int.max 0 width in
  if width = 0 then [] else
  let tabs = Array.of_list tabs in
  let count = Array.length tabs in
  if count = 0 then [ Span.blank Status width ] else
  let active = Option.value (Array.findi tabs ~f:(fun _ t -> t.active) |> Option.map ~f:fst) ~default:0 in
  let token i ~limit =
    let t = tabs.(i) in
    let prefix = sprintf "%s%d:" (if t.active then "[" else " ") (i + 1) in
    let suffix = (if t.modified then "*" else "") ^ (if t.active then "]" else " ") in
    let room = limit - String.length prefix - String.length suffix in
    if room < 1 then String.prefix (if t.modified then "*" else "[" ^ Int.to_string (i + 1)) limit
    else
      let label = if String.length t.label <= room then t.label
        else String.prefix t.label (room - 1) ^ "~" in
      prefix ^ label ^ suffix in
  let lo = ref active and hi = ref active in
  let cost l h =
    (if l > 0 then 1 else 0) + (if h < count - 1 then 1 else 0)
    + List.sum (module Int) (List.range l (h + 1)) ~f:(fun i -> String.length (token i ~limit:40)) in
  (* Prefer the preceding neighbor, then the following one; never skip a tab. *)
  let rec grow () =
    if !lo > 0 && cost (!lo - 1) !hi <= width then (decr lo; grow ())
    else if !hi < count - 1 && cost !lo (!hi + 1) <= width then (incr hi; grow ()) in
  grow ();
  let left = if !lo > 0 && width >= 3 then 1 else 0 in
  let right = if !hi < count - 1 && width >= 3 then 1 else 0 in
  let available = width - left - right in
  let body = List.map (List.range !lo (!hi + 1)) ~f:(fun i ->
    let text = token i ~limit:(Int.min available 40) in
    Span.create (if tabs.(i).active then Title else Hint) text ~width:(String.length text)) in
  let used = List.sum (module Int) body ~f:(fun s -> s.Span.width) in
  (if left = 1 then [ Span.create Hint "<" ~width:1 ] else [])
  @ body @ [ Span.blank Status (available - used) ]
  @ (if right = 1 then [ Span.create Hint ">" ~width:1 ] else [])
;;
