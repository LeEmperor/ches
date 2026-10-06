open! Core

module Syntax = struct
  (* Phase 2 will supply provider-independent categories. No syntax colors yet. *)
  type t = Plain [@@deriving sexp_of, equal]
end

module Overlay = struct
  type t =
    | Search_match
    | Search_current
    | Selection
    | Insert_cursor
    | Insert_point
  [@@deriving sexp_of, equal, enumerate]
end

module Document = struct
  type t =
    { syntax : Syntax.t
    ; current_line : bool
    ; special : bool
    ; overlay : Overlay.t option
    }
  [@@deriving sexp_of, equal]

  let create ?(syntax = Syntax.Plain) ?(current_line = false) ?(special = false) ?overlay () =
    { syntax; current_line; special; overlay }
  ;;
end

module Chrome = struct
  type t =
    | Classic
    | Open
  [@@deriving sexp_of, equal]
end

type t =
  | Backdrop
  | Document of Document.t
  | Gutter
  | Gutter_cursor_line
  | Border
  | Border_focused
  | Title
  | Title_special
  | Status
  | Status_special
  | Hint
  | Separator
  | Mode of Ches_core.Mode.t
  | Dirty
  | Pending
  | Info
  | Warning
  | Error
  | Smear
[@@deriving sexp_of, equal]

let document ?syntax ?current_line ?special ?overlay () =
  Document (Document.create ?syntax ?current_line ?special ?overlay ())
;;

let with_overlay style overlay =
  match style with
  | Document text -> Document { text with overlay = Some overlay }
  | _ -> invalid_arg "Style.with_overlay: expected a document style"
;;

(* Frame dumps describe the effective appearance, preserving their compact labels.
   [sexp_of_t] still exposes every component for structural debugging/tests. *)
let to_string_hum = function
  | Document { syntax = Plain; current_line; special; overlay } ->
    (match overlay with
     | Some Insert_cursor -> "Insert_cursor"
     | Some Insert_point -> "Insert_point"
     | Some Selection -> if special then "Selection_special" else "Selection"
     | Some Search_match -> if special then "Search_special_match" else "Search_match"
     | Some Search_current ->
       if special then "Search_special_match_current" else "Search_match_current"
     | None ->
       (match special, current_line with
        | false, false -> "Text"
        | false, true -> "Text_cursor_line"
        | true, false -> "Special"
        | true, true -> "Special_cursor_line"))
  | style -> Sexp.to_string_hum (sexp_of_t style)
;;
