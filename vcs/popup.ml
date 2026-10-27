open! Core

module Switch = struct
  type t =
    { key : char
    ; flag : string
    ; description : string
    ; group : string option
    }
  [@@deriving sexp, equal]
end

module Action = struct
  type 'a t =
    { key : char
    ; description : string
    ; run : (enabled:string list -> 'a[@sexp.opaque])
    }
  [@@deriving sexp_of]
end

type 'a t =
  { title : string
  ; switches : Switch.t list
  ; actions : 'a Action.t list
  }
[@@deriving sexp_of]

let reserved = [ '-'; 'q'; '?' ]

let valid_key key =
  Char.to_int key > 0x20
  && Char.to_int key < 0x7f
  && not (List.mem reserved key ~equal:Char.equal)
;;

let create ~title ~switches ~actions =
  let check condition message = if condition then Ok () else Or_error.error_string message in
  let unique list ~compare = Option.is_none (List.find_a_dup list ~compare) in
  let open Or_error.Let_syntax in
  let%bind () = check (not (String.is_empty title)) "Popup title is empty" in
  let keys =
    List.map switches ~f:(fun (s : Switch.t) -> s.key)
    @ List.map actions ~f:(fun (a : _ Action.t) -> a.key)
  in
  let%bind () =
    match List.find keys ~f:(Fn.non valid_key) with
    | None -> Ok ()
    | Some key -> Or_error.error_s [%message "Popup key is reserved or not printable" (key : char)]
  in
  let%bind () =
    check
      (unique (List.map switches ~f:(fun (s : Switch.t) -> s.key)) ~compare:Char.compare)
      "Popup switch key used twice"
  in
  let%bind () =
    check
      (unique (List.map actions ~f:(fun (a : _ Action.t) -> a.key)) ~compare:Char.compare)
      "Popup action key used twice"
  in
  let flags = List.map switches ~f:(fun (s : Switch.t) -> s.flag) in
  let%bind () =
    check
      (List.for_all flags ~f:(Fn.non String.is_empty) && unique flags ~compare:String.compare)
      "Popup switch flags must be nonempty and unique"
  in
  let%bind () =
    check
      (List.for_all switches ~f:(fun (s : Switch.t) -> not (String.is_empty s.description))
       && List.for_all actions ~f:(fun (a : _ Action.t) -> not (String.is_empty a.description)))
      "Popup entry description is empty"
  in
  let%map () =
    check
      (List.for_all switches ~f:(fun (s : Switch.t) ->
         Option.for_all s.group ~f:(Fn.non String.is_empty)))
      "Popup switch group is empty"
  in
  { title; switches; actions }
;;

module State = struct
  type t =
    { enabled : string list
    ; dash : bool
    }
  [@@deriving sexp, equal]
end

let same_group (a : Switch.t) (b : Switch.t) =
  match a.group, b.group with
  | Some a, Some b -> String.equal a b
  | _ -> false
;;

let switch_of_flag t flag = List.find t.switches ~f:(fun s -> String.equal s.flag flag)

(* Flags in declaration order. *)
let ordered t flags =
  List.filter_map t.switches ~f:(fun s ->
    Option.some_if (List.mem flags s.flag ~equal:String.equal) s.flag)
;;

let initial ?(enabled = []) t =
  let kept =
    List.fold enabled ~init:[] ~f:(fun kept flag ->
      match switch_of_flag t flag with
      | None -> kept
      | Some switch ->
        if List.exists kept ~f:(fun other ->
             match switch_of_flag t other with
             | Some other -> String.equal other.flag switch.flag || same_group other switch
             | None -> false)
        then kept
        else flag :: kept)
  in
  { State.enabled = ordered t kept; dash = false }
;;

let toggle t (state : State.t) (switch : Switch.t) =
  let enabled =
    if List.mem state.enabled switch.flag ~equal:String.equal
    then List.filter state.enabled ~f:(fun flag -> not (String.equal flag switch.flag))
    else
      switch.flag
      :: List.filter state.enabled ~f:(fun flag ->
        match switch_of_flag t flag with
        | Some other -> not (same_group other switch)
        | None -> false)
  in
  { State.enabled = ordered t enabled; dash = false }
;;

module Reply = struct
  type 'a t =
    | Updated of State.t
    | Run of 'a
    | Unbound of
        { state : State.t
        ; key : string
        }
  [@@deriving sexp_of]
end

let press t (state : State.t) key : _ Reply.t =
  if state.dash
  then
    if Char.equal key '-'
    then Updated state
    else (
      match List.find t.switches ~f:(fun s -> Char.equal s.key key) with
      | Some switch -> Updated (toggle t state switch)
      | None -> Unbound { state = { state with dash = false }; key = sprintf "-%c" key })
  else if Char.equal key '-'
  then Updated { state with dash = true }
  else (
    match List.find t.actions ~f:(fun a -> Char.equal a.key key) with
    | Some action -> Run (action.run ~enabled:state.enabled)
    | None -> Unbound { state; key = String.of_char key })
;;

let escape (state : State.t) =
  if state.dash then `Updated { state with dash = false } else `Close
;;

let enabled t (state : State.t) =
  List.filter t.switches ~f:(fun s -> List.mem state.enabled s.flag ~equal:String.equal)
;;

let help t =
  List.map t.switches ~f:(fun s ->
    sprintf "-%c" s.key, sprintf "%s (%s)" s.description s.flag)
  @ List.map t.actions ~f:(fun a -> String.of_char a.key, a.description)
;;
