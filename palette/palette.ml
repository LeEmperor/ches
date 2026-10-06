open! Core

module Event = struct
  type t =
    | Insert of Uchar.t
    | Paste of string
    | Backspace
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
  let ids = result_ids t in
  let selected =
    match t.selected with
    | Some id when List.mem ids id ~equal:Catalog.Id.equal -> Some id
    | _ -> List.hd ids
  in
  { t with selected }
;;

let create catalog context ~token =
  refresh { catalog; context; token; query = ""; results = []; selected = None }
;;

let is_control scalar = scalar <= 0x1F || (scalar >= 0x7F && scalar <= 0x9F)

(* [s] as single-line query text; see the interface. *)
let sanitize s =
  let buffer = Buffer.create (String.length s) in
  let rec loop pos =
    if pos < String.length s
    then
      if String.is_substring_at s ~pos ~substring:"\r\n"
      then (
        Buffer.add_char buffer ' ';
        loop (pos + 2))
      else (
        let decoded = Stdlib.String.get_utf_8_uchar s pos in
        let u = Stdlib.Uchar.utf_decode_uchar decoded in
        (match Uchar.to_scalar u with
         | 0x0A | 0x0D | 0x09 -> Buffer.add_char buffer ' '
         | scalar when is_control scalar -> ()
         | _ -> Stdlib.Buffer.add_utf_8_uchar buffer u);
        loop (pos + Stdlib.Uchar.utf_decode_length decoded))
  in
  loop 0;
  Buffer.contents buffer
;;

let append t text =
  match sanitize text with
  | "" -> t
  | text -> refresh { t with query = t.query ^ text }
;;

(* The query is valid UTF-8, so the last code point starts at the last byte that is
   not a continuation byte. *)
let backspace t =
  match String.rfindi t.query ~f:(fun _ c -> Char.to_int c land 0xC0 <> 0x80) with
  | None -> t
  | Some start -> refresh { t with query = String.prefix t.query start }
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
