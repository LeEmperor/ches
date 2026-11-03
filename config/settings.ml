open Core

type t =
  { completion_enabled : bool
  ; signature_help_enabled : bool
  ; completion_ghost_preview : bool
  ; completion_min_prefix_chars : int
  ; completion_prefer_local_snippets : bool
  ; line_numbers : bool
  ; theme : string
  ; snippets : Ches_completion.User_snippets.operation list
  }
[@@deriving sexp, equal]

let default =
  { completion_enabled = true
  ; signature_help_enabled = true
  ; completion_ghost_preview = false
  ; completion_min_prefix_chars = 1
  ; completion_prefer_local_snippets = true
  ; line_numbers = false
  ; theme = "vim-classic"
  ; snippets = []
  }
;;

let validate t =
  if t.completion_min_prefix_chars < 1
  then Or_error.error_string "completion_min_prefix_chars must be positive"
  else if String.is_empty (String.strip t.theme)
  then Or_error.error_string "theme must be nonempty"
  else
    Or_error.map
      (Ches_completion.User_snippets.apply Ches_completion.User_snippets.builtins t.snippets)
      ~f:(fun _ -> t)
;;
