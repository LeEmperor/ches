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

type t =
  { config : Config.t
  ; count : int option (** Digits typed before a Normal-mode sequence. *)
  ; pending : Key.t list (** Keys of an incomplete Normal-mode sequence, in order. *)
  ; escape_started : bool
  (** The previous input inserted the first character of [config.insert_escape]. *)
  ; notice : string option
  }
[@@deriving sexp_of]

let create (config : Config.t) =
  (match config.tab with
   | Spaces n when n < 1 -> raise_s [%message "Keymap.create: [Spaces n] needs n >= 1"]
   | Spaces _ | Literal_tab -> ());
  { config; count = None; pending = []; escape_started = false; notice = None }
;;

(* The state between sequences: only the configuration carries over. *)
let reset t = create t.config
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
  | Editor command, None -> reset t, [ Editor command ]
  | View command, None -> reset t, [ View command ]
  | (Editor _ | View _), Some _ ->
    cancel t (keys_to_string keys ^ " does not take a count")
;;

let feed_normal_key t (key : Key.t) =
  match key, Key.digit key with
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
      | Backspace ->
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

let quit_hint = "To quit, use Space q in Normal mode"

let feed t ~(mode : Mode.t) (input : Input.t) =
  match mode, input with
  | _, Key (Ctrl 'c') -> { (reset t) with notice = Some quit_hint }, []
  | Normal, Key key -> feed_normal_key t key
  | Normal, Paste _ -> cancel t "Paste ignored in Normal mode"
  | Insert, Key key -> feed_insert_key t key
  | Insert, Paste text ->
    reset t, if String.is_empty text then [] else [ Action.Editor (Insert_text text) ]
;;

let pending t =
  if List.is_empty t.pending && Option.is_none t.count
  then None
  else Some (keys_to_string ?count:t.count t.pending)
;;
let notice t = t.notice
