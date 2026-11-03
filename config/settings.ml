open Core

type t =
  { completion_enabled : bool
  ; signature_help_enabled : bool
  ; completion_ghost_preview : bool
  ; completion_min_prefix_chars : int
  ; completion_prefer_local_snippets : bool
  ; completion_colors : (string * string) list
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
  ; completion_colors = []
  ; line_numbers = false
  ; theme = "vim-classic"
  ; snippets = []
  }
;;

let validate_colors colors =
  let roles =
    [ "background"; "selected_background"; "label"; "selected_label"
    ; "source"; "selected_source"; "detail"; "selected_detail"
    ; "match"; "selected_match"; "documentation" ]
  in
  Or_error.try_with (fun () ->
    List.fold colors ~init:[] ~f:(fun acc (role, color) ->
      if not (List.mem roles role ~equal:String.equal) then
        invalid_arg ("unknown completion color role: " ^ role);
      if String.length color <> 7 || not (Char.equal color.[0] '#')
         || not (String.for_all (String.drop_prefix color 1) ~f:(function
           | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false))
      then invalid_arg ("completion color must be #RRGGBB: " ^ color);
      List.Assoc.remove acc role ~equal:String.equal
      @ [role, String.lowercase color]))
;;

let validate t =
  if t.completion_min_prefix_chars < 1
  then Or_error.error_string "completion_min_prefix_chars must be positive"
  else if String.is_empty (String.strip t.theme)
  then Or_error.error_string "theme must be nonempty"
  else
    Or_error.bind (validate_colors t.completion_colors) ~f:(fun completion_colors ->
    Or_error.map
      (Ches_completion.User_snippets.apply Ches_completion.User_snippets.builtins t.snippets)
      ~f:(fun _ -> { t with completion_colors }))
;;
