open! Core

module Role = struct
  type t =
    | Major
    | Minor
  [@@deriving sexp_of, equal]
end

type t =
  { id : View_id.t
  ; title : string
  ; role : Role.t
  ; focusable : bool
  ; accepts_paste : bool
  ; owns_cursor : bool
  }
[@@deriving sexp_of]

let primary id ~title =
  { id; title; role = Major; focusable = true; accepts_paste = true; owns_cursor = true }
;;

let read_only id ~title =
  { id; title; role = Minor; focusable = true; accepts_paste = false; owns_cursor = false }
;;

let companion id ~title =
  { id; title; role = Minor; focusable = false; accepts_paste = false; owns_cursor = false }
;;
