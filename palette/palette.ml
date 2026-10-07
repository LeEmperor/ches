open! Core

module Event = struct
  type t =
    | Insert of Uchar.t
    | Paste of string
    | Backspace
    | Delete_word
    | Next
    | Previous
  [@@deriving sexp_of]
end

module Request = struct
  type 'token t =
    { token : 'token
    ; id : Catalog.Id.t
    ; action : Ches_input.Keymap.Action.t
    }
  [@@deriving sexp_of]
end

module Accept = struct
  type 'token t =
    | Execute of 'token Request.t
    | No_selection
    | Target_gone of 'token
    | Unavailable of
        { token : 'token
        ; id : Catalog.Id.t
        }
  [@@deriving sexp_of]
end

type 'token t =
  { catalog : Catalog.t
  ; context : Catalog.Context.t
  ; token : 'token
  ; query : string
  ; results : Catalog.result list
  ; selected : Catalog.Id.t option
  }
[@@deriving fields ~getters]

let result_ids t =
  List.map t.results ~f:(fun (result : Catalog.result) -> Catalog.Entry.id result.item)
;;

let refresh t =
  let t = { t with results = Catalog.search t.catalog t.context ~query:t.query } in
  let selected =
    Selection.preserve t.selected t.results
      ~id:(fun (result : Catalog.result) -> Catalog.Entry.id result.item)
      ~equal:Catalog.Id.equal
  in
  { t with selected }
;;

let create catalog context ~token =
  refresh { catalog; context; token; query = ""; results = []; selected = None }
;;

let sanitize = Query.sanitize

let append t text =
  match sanitize text with
  | "" -> t
  | text -> refresh { t with query = t.query ^ text }
;;

(* The query is valid UTF-8, so the last code point starts at the last byte that is
   not a continuation byte. *)
let backspace t =
  let query = Query.backspace t.query in
  if String.equal query t.query then t else refresh { t with query }
;;

(* Trailing spaces, then the word before them, as readline's Ctrl-w does. Space is the
   only whitespace a query holds, and it is ASCII, so cutting next to one keeps the
   query valid UTF-8. *)
let delete_word t =
  let query = Query.delete_word t.query in
  if String.equal query t.query then t else refresh { t with query }
;;

let move t ~by =
  match t.selected with
  | None -> t
  | Some id ->
    let ids = Array.of_list (result_ids t) in
    (match Array.findi ids ~f:(fun _ candidate -> Catalog.Id.equal candidate id) with
     | None -> t
     | Some (index, _) ->
       let index = Int.clamp_exn (index + by) ~min:0 ~max:(Array.length ids - 1) in
       { t with selected = Some ids.(index) })
;;

let update t (event : Event.t) =
  match event with
  | Insert u -> append t (Uchar.Utf8.to_string u)
  | Paste text -> append t text
  | Backspace -> backspace t
  | Delete_word -> delete_word t
  | Next -> move t ~by:1
  | Previous -> move t ~by:(-1)
;;

let accept t ~context : _ Accept.t =
  match t.selected, context with
  | None, _ -> No_selection
  | Some _, None -> Target_gone t.token
  | Some id, Some context ->
    (match Catalog.find t.catalog id with
     | Some entry when Catalog.Entry.is_available entry context ->
       Execute { token = t.token; id; action = Catalog.Entry.action entry }
     | _ -> Unavailable { token = t.token; id })
;;
