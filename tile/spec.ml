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
  ; accepts_text : bool
  ; accepts_tab : bool
  }
[@@deriving sexp_of]

let primary id ~title =
  { id; title; role = Major; focusable = true; accepts_paste = true
  ; owns_cursor = true
  ; accepts_text = false
  ; accepts_tab = false
  }
;;

let read_only id ~title =
  { id
  ; title
  ; role = Minor
  ; focusable = true
  ; accepts_paste = false
  ; owns_cursor = false
  ; accepts_text = false
  ; accepts_tab = false
  }
;;

let read_only_text id ~title = { (read_only id ~title) with owns_cursor = true }

let companion id ~title =
  { id
  ; title
  ; role = Minor
  ; focusable = false
  ; accepts_paste = false
  ; owns_cursor = false
  ; accepts_text = false
  ; accepts_tab = false
  }
;;

let text_input id ~title =
  { id
  ; title
  ; role = Minor
  ; focusable = true
  ; accepts_paste = true
  ; owns_cursor = true
  ; accepts_text = true
  ; accepts_tab = false
  }
;;

let result_picker id ~title = { (text_input id ~title) with accepts_tab = true }
