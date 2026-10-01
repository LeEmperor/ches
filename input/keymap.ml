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
    }
  [@@deriving sexp_of]

  let default = { tab = Spaces 2; insert_escape = Some ('j', 'k') }
end

type t =
  { config : Config.t
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
  { config; pending = []; escape_started = false; notice = None }
;;

(* The state between sequences: only the configuration carries over. *)
let reset t = create t.config

let normal_bindings : (Key.t list * Command.t) list =
  let leader = Key.char ' ' in
  [ [ Key.char 'h' ], Move Left
  ; [ Key.char 'j' ], Move Down
  ; [ Key.char 'k' ], Move Up
  ; [ Key.char 'l' ], Move Right
  ; [ Key.char 'i' ], Enter_insert
  ; [ Key.char 'x' ], Delete_char
  ; [ Key.char 'u' ], Undo
  ; [ Ctrl 'r' ], Redo
  ; [ leader; Key.char 'w' ], Save
  ; [ leader; Key.char 'q' ], Quit
  ; [ leader; Key.char 'Q' ], Force_quit
  ]
;;

let keys_to_string keys = List.map keys ~f:Key.to_string_hum |> String.concat ~sep:" "

let feed_normal_key t (key : Key.t) =
  let keys = t.pending @ [ key ] in
  match List.Assoc.find normal_bindings keys ~equal:[%equal: Key.t list] with
  | Some command -> reset t, [ command ]
  | None ->
    let is_prefix (sequence, _) =
      List.is_prefix sequence ~prefix:keys ~equal:Key.equal
    in
    if List.exists normal_bindings ~f:is_prefix
    then { (reset t) with pending = keys }, []
    else (
      match t.pending, key with
      | [], _ | _, Escape -> reset t, []
      | _ :: _, _ ->
        { (reset t) with notice = Some (keys_to_string keys ^ " is not bound") }, [])
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
    reset t, [ Command.Delete_backward; Exit_insert ]
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
      | Char _ | Enter | Ctrl _ ->
        (match Key.text key with
         | Some text -> [ Insert_text text ]
         | None -> [])
    in
    { (reset t) with escape_started = is_escape_char 0 }, commands)
;;

let feed t ~(mode : Mode.t) (input : Input.t) =
  match mode, input with
  | Normal, Key key -> feed_normal_key t key
  | Normal, Paste _ -> { (reset t) with notice = Some "Paste ignored in Normal mode" }, []
  | Insert, Key key -> feed_insert_key t key
  | Insert, Paste text ->
    reset t, if String.is_empty text then [] else [ Insert_text text ]
;;

let pending t = if List.is_empty t.pending then None else Some (keys_to_string t.pending)
let notice t = t.notice
