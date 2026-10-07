module Editor_command = Ches_core.Command
open! Core
open Ches_core
module Command = Editor_command

module Input = struct
  type t =
    | Key of Key.t
    | Paste of string
  [@@deriving sexp_of]
end

module Config = struct
  type tab =
    | Literal_tab
    | Spaces of int
  [@@deriving sexp_of]

  type t =
    { tab : tab
    ; insert_escape : (char * char) option
    ; normal : Bindings.t
    }
  [@@deriving sexp_of]

  let default =
    { tab = Spaces 2; insert_escape = Some ('j', 'k'); normal = Bindings.default }
  ;;
end

module Action = struct
  type t =
    | Editor of Command.t
    | View of View_command.t
  [@@deriving equal]

  let sexp_of_t = function
    | Editor command -> [%sexp (command : Command.t)]
    | View view -> [%sexp View (view : View_command.t)]
  ;;
end

module Operator = struct
  type t =
    | Delete
    | Yank
  [@@deriving sexp_of, equal]

  let key = function
    | Delete -> Key.char 'd'
    | Yank -> Key.char 'y'
  ;;
end

type t =
  { config : Config.t
  ; count : int option (** Digits typed before a Normal-mode sequence. *)
  ; operator_count : int option (** Count before a pending operator. *)
  ; operator : Operator.t option
  ; command_prompt : string option
  ; pending : Key.t list (** Keys of an incomplete Normal-mode sequence, in order. *)
  ; escape_started : bool
  (** The previous input inserted the first character of [config.insert_escape]. *)
  ; notice : string option
  ; find : (Ches_core.Motion.Find.direction * bool) option
  ; search_prompt : (bool * string) option
  }
[@@deriving sexp_of]

let create (config : Config.t) =
  (match config.tab with
   | Spaces n when n < 1 -> raise_s [%message "Keymap.create: [Spaces n] needs n >= 1"]
   | Spaces _ | Literal_tab -> ());
  { config
  ; count = None
  ; operator_count = None
  ; operator = None
  ; command_prompt = None
  ; pending = []
  ; escape_started = false
  ; notice = None
  ; find = None
  ; search_prompt = None
  }
;;

(* The state between sequences: only the configuration carries over. *)
let reset t = create t.config
let lookup t keys = Bindings.find t.config.normal keys
let bindings t = t.config.normal
let config t = t.config
let cancel t notice = { (reset t) with notice = Some notice }, []

let keys_to_string ?count keys =
  Option.to_list (Option.map count ~f:Int.to_string) @ List.map keys ~f:Key.to_string_hum
  |> String.concat ~sep:" "
;;

let resolve t ~keys (target : Bindings.Target.t) =
  match target, t.count with
  | Move motion, Some _ when not (Motion.takes_count motion) ->
    cancel t (keys_to_string keys ^ " does not take a count")
  | Move motion, count -> reset t, [ Action.Editor (Move { motion; count }) ]
  | Scroll scroll, Some _ when not (View_command.Scroll.takes_count scroll) ->
    cancel t (keys_to_string keys ^ " does not take a count")
  | Scroll scroll, count -> reset t, [ View (Scroll { scroll; count }) ]
  | (Delete_operator | Yank_operator), count ->
    let operator = match target with Delete_operator -> Operator.Delete | Yank_operator -> Operator.Yank | _ -> assert false in
    { (reset t) with operator_count = count; operator = Some operator; pending = [ Operator.key operator ] }, []
  | Delete_chars_forward, count ->
    reset t, [ Editor (Delete_chars_forward (Option.value count ~default:1)) ]
  | Delete_chars_backward, count ->
    reset t, [ Editor (Delete_chars_backward (Option.value count ~default:1)) ]
  | Delete_to_line_end, count ->
    reset t, [ Editor (Delete_motion { motion = Line_end; count }) ]
  | Paste { before }, count ->
    reset t, [ Editor (Paste { before; count = Option.value count ~default:1 }) ]
  | Editor command, None -> reset t, [ Editor command ]
  | View command, None -> reset t, [ View command ]
  | Find { direction; till }, count ->
    { (reset t) with count; pending = keys; find = Some (direction, till) }, []
  | Repeat_find { opposite }, count ->
    reset t, [ Editor (Repeat_find { opposite; count = Option.value count ~default:1 }) ]
  | Search_prompt { forward }, None ->
    { (reset t) with search_prompt = Some (forward, "") }, []
  | Search_prompt _, Some _ -> cancel t (keys_to_string keys ^ " does not take a count")
  | Repeat_search { opposite }, count ->
    reset t, [ Editor (Command.Search { query = None; forward = not opposite; count = Option.value count ~default:1; whole_word = false }) ]
  | Search_word { forward }, None -> reset t, [ Editor (Command.Search_word { forward }) ]
  | Search_word _, Some _ -> cancel t (keys_to_string keys ^ " does not take a count")
  | Visual kind, None -> reset t, [ Editor (Command.Enter_visual kind) ]
  | Visual _, Some _ -> cancel t (keys_to_string keys ^ " does not take a count")
  | (Editor _ | View _), Some _ ->
    cancel t (keys_to_string keys ^ " does not take a count")
;;

let multiplied_count t =
  let left = Option.value t.operator_count ~default:1 in
  let right = Option.value t.count ~default:1 in
  if left > Command.max_count / right
  then Error (sprintf "Count is too large: the maximum is %d" Command.max_count)
  else Ok (left * right)
;;

let feed_operator_key t operator key =
  let operator_key = Operator.key operator in
  if Operator.equal operator Delete && Key.equal key (Key.char 'i') && List.length t.pending = 1
  then { t with pending = [ Key.char 'd'; Key.char 'i' ] }, []
  else if List.length t.pending = 2 && Key.equal (List.nth_exn t.pending 1) (Key.char 'i')
  then (
    if Key.equal key (Key.char 'w')
    then (
      if Option.is_some t.operator_count || Option.is_some t.count
      then cancel t "diw does not take a count"
      else reset t, [ Action.Editor Delete_inner_word ])
    else cancel t (keys_to_string (t.pending @ [ key ]) ^ " is not a text object"))
  else if Key.equal key operator_key && List.length t.pending = 1
  then (
    match multiplied_count t with
    | Error notice -> cancel t notice
    | Ok count ->
      let command =
        match operator with
        | Delete -> Command.Delete_lines count
        | Yank -> Command.Yank_lines count
      in
      reset t, [ Action.Editor command ])
  else match key, Key.digit key with
  | Escape, _ -> reset t, []
  | _, Some digit when List.length t.pending = 1 && (digit > 0 || Option.is_some t.count) ->
    let count = (Option.value t.count ~default:0 * 10) + digit in
    if count > Command.max_count
    then cancel t (sprintf "Count is too large: the maximum is %d" Command.max_count)
    else { t with count = Some count }, []
  | _ ->
    let motion_keys = List.drop t.pending 1 @ [ key ] in
    (match Bindings.find t.config.normal motion_keys with
      | Prefix -> { t with pending = operator_key :: motion_keys }, []
      | Bound (Find { direction; till }) ->
        { t with pending = operator_key :: motion_keys; find = Some (direction, till) }, []
      | Bound (Repeat_find { opposite }) ->
        (match multiplied_count t with
         | Error notice -> cancel t notice
         | Ok count ->
           let command = match operator with Delete -> Command.Delete_repeat_find { opposite; count } | Yank -> Command.Yank_repeat_find { opposite; count } in
           reset t, [ Action.Editor command ])
      | Bound (Move motion) ->
       (match multiplied_count t with
        | Error notice -> cancel t notice
        | Ok count ->
          let explicit_count = Option.is_some t.operator_count || Option.is_some t.count in
          if explicit_count && not (Motion.takes_count motion)
          then cancel t (keys_to_string ~count motion_keys ^ " does not take a count")
          else
            let count = Option.some_if explicit_count count in
            let command =
              match operator with
              | Delete -> Command.Delete_motion { motion; count }
              | Yank -> Command.Yank_motion { motion; count }
            in
            reset t, [ Action.Editor command ])
     | Bound _ | Unbound ->
        cancel t (keys_to_string ?count:t.count (operator_key :: motion_keys) ^ " is not a motion"))
;;

let feed_normal_key t (key : Key.t) =
  if Option.is_some t.find
  then (
    match key with
    | Escape -> reset t, []
    | Char target ->
      let direction, till = Option.value_exn t.find in
      let motion = Motion.Find { target; direction; till } in
      (match t.operator with
       | None -> reset t, [ Action.Editor (Command.Move { motion; count = t.count }) ]
       | Some operator ->
         (match multiplied_count t with
          | Error notice -> cancel t notice
          | Ok count ->
            let count = Option.some_if (Option.is_some t.operator_count || Option.is_some t.count) count in
            let command = match operator with Delete -> Command.Delete_motion { motion; count } | Yank -> Command.Yank_motion { motion; count } in
            reset t, [ Action.Editor command ]))
    | _ -> cancel t "Find needs a character")
  else if Option.is_some t.operator
  then feed_operator_key t (Option.value_exn t.operator) key
  else match key, Key.digit key with
  | Escape, _ when List.is_empty t.pending && Option.is_none t.count ->
    reset t, [ Action.Editor Command.Clear_search_highlight ]
  | Escape, _ -> reset t, []
  (* Digits extend a count before a sequence; [0] starts one only after another digit,
     so that it can be bound on its own. *)
  | _, Some digit when List.is_empty t.pending && (digit > 0 || Option.is_some t.count) ->
    let count = (Option.value t.count ~default:0 * 10) + digit in
    if count > Command.max_count
    then cancel t (sprintf "Count is too large: the maximum is %d" Command.max_count)
    else { (reset t) with count = Some count }, []
  | _ ->
    let keys = t.pending @ [ key ] in
    (match Bindings.find t.config.normal keys with
     | Bound target -> resolve t ~keys target
     | Prefix -> { (reset t) with count = t.count; pending = keys }, []
     | Unbound ->
       if List.is_empty t.pending && Option.is_none t.count
       then reset t, []
       else cancel t (keys_to_string ?count:t.count keys ^ " is not bound"))
;;

let feed_command_prompt t input =
  let prompt = Option.value_exn t.command_prompt in
  match input with
  | Input.Key Escape -> reset t, []
  | Input.Key Enter ->
    if String.equal prompt "e!"
    then reset t, [ Action.Editor Reload ]
    else cancel t (sprintf "Unknown command: :%s" prompt)
  | Input.Key (Backspace | Ctrl 'h') ->
    let prompt = String.drop_suffix prompt 1 in
    { t with command_prompt = Some prompt }, []
  | Input.Key key ->
    (match Key.text key with
     | None -> t, []
     | Some text -> { t with command_prompt = Some (prompt ^ text) }, [])
  | Input.Paste text -> { t with command_prompt = Some (prompt ^ text) }, []
;;

let drop_last_code_point s =
  let rec start i =
    if i = 0 || Char.to_int s.[i] land 0xC0 <> 0x80 then i else start (i - 1)
  in
  if String.is_empty s then s else String.prefix s (start (String.length s - 1))
;;

let feed_search_prompt t input =
  let forward, query = Option.value_exn t.search_prompt in
  match input with
  | Input.Key Escape -> reset t, []
  | Input.Key Enter ->
    reset t, [ Action.Editor (Command.Search { query = Some query; forward; count = 1; whole_word = false }) ]
  | Input.Key (Backspace | Ctrl 'h') -> { t with search_prompt = Some (forward, drop_last_code_point query) }, []
  | Input.Key key ->
    (match Key.text key with
     | None -> t, []
     | Some text -> { t with search_prompt = Some (forward, query ^ text) }, [])
  | Input.Paste text -> { t with search_prompt = Some (forward, query ^ text) }, []
;;

let feed_insert_key t (key : Key.t) =
  let is_escape_char i =
    match t.config.insert_escape with
    | None -> false
    | Some pair -> Key.equal key (Key.char (if i = 0 then fst pair else snd pair))
  in
  if t.escape_started && is_escape_char 1
  then
    (* The first character was inserted when typed; take it back before leaving. *)
    reset t, [ Action.Editor Delete_backward; Editor Exit_insert ]
  else (
    let commands : Command.t list =
      match key with
      | Escape -> [ Exit_insert ]
      | Delete -> [ Delete_forward ]
      | Backspace | Ctrl 'h' ->
        (match t.config.tab with
         | Literal_tab -> [ Delete_backward ]
         | Spaces width -> [ Delete_soft_tab_backward width ])
      | Tab ->
        (match t.config.tab with
         | Literal_tab -> [ Insert_text "\t" ]
         | Spaces width -> [ Insert_soft_tab width ])
      | Enter -> [ Insert_newline ]
      | Char _ | Ctrl _ ->
        (match Key.text key with
         | Some text -> [ Insert_text text ]
         | None -> [])
    in
    ( { (reset t) with escape_started = is_escape_char 0 }
    , List.map commands ~f:(fun command -> Action.Editor command) ))
;;

let feed_visual_key t key =
  let visual_insert ~append =
    reset t, [ Action.Editor (Command.Visual_insert { append; count = Option.value t.count ~default:1 }) ]
  in
  (* A pending sequence, such as [f] waiting for its character, takes the key. *)
  if (not (List.is_empty t.pending)) || Option.is_some t.find
  then feed_normal_key t key
  else (
    match key with
    | Key.Escape -> reset t, [ Action.Editor Command.Exit_visual ]
    | Key.Char c when Uchar.to_scalar c = Char.to_int 'd' -> reset t, [ Action.Editor Command.Visual_delete ]
    | Key.Char c when Uchar.to_scalar c = Char.to_int 'y' -> reset t, [ Action.Editor Command.Visual_yank ]
    | Key.Char c when Uchar.to_scalar c = Char.to_int 'c' -> reset t, [ Action.Editor Command.Visual_change ]
    | Key.Char c when Uchar.to_scalar c = Char.to_int 'I' -> visual_insert ~append:false
    | Key.Char c when Uchar.to_scalar c = Char.to_int 'A' -> visual_insert ~append:true
    | _ -> feed_normal_key t key)
;;

let quit_hint = "To quit, use Space q in Normal mode"

let feed t ~(mode : Mode.t) (input : Input.t) =
  match input with
  | Input.Key (Ctrl 'c') -> { (reset t) with notice = Some quit_hint }, []
  | _ ->
    if Option.is_some t.command_prompt
    then feed_command_prompt t input
    else if Option.is_some t.search_prompt
    then feed_search_prompt t input
    else match mode, input with
    | Normal, Key key when Key.equal key (Key.char ':') ->
      { t with command_prompt = Some "" }, []
    | Normal, Key key -> feed_normal_key t key
    | Normal, Paste _ -> cancel t "Paste ignored in Normal mode"
    | Insert, Key key -> feed_insert_key t key
    | Insert, Paste text ->
       reset t, if String.is_empty text then [] else [ Action.Editor (Insert_text text) ]
    | Visual _, Key key -> feed_visual_key t key
    | Visual _, Paste _ -> cancel t "Paste ignored in Visual mode"
;;

let pending t =
  match t.command_prompt with
  | Some prompt -> Some (":" ^ prompt)
  | None ->
    (match t.search_prompt with
     | Some (forward, query) -> Some ((if forward then "/" else "?") ^ query)
     | None when List.is_empty t.pending && Option.is_none t.count -> None
     | None ->
    match t.operator with
    | Some operator ->
      let operator =
        Option.to_list (Option.map t.operator_count ~f:Int.to_string)
        @ [ Key.to_string_hum (Operator.key operator) ]
      in
      let motion = Option.to_list (Option.map t.count ~f:Int.to_string) in
      Some (String.concat ~sep:" " (operator @ motion @ List.map (List.drop t.pending 1) ~f:Key.to_string_hum))
    | None -> Some (keys_to_string ?count:t.count t.pending))
;;

let search_preview t = Option.map t.search_prompt ~f:snd
let notice t = t.notice
