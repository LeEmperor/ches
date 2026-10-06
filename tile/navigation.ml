open! Core
open Ches_input

module Motion = struct
  type t =
    | Down
    | Up
    | Half_down
    | Half_up
    | First
    | Last
  [@@deriving sexp_of, equal]

  let delta t ~rows =
    let half = Int.max 1 (rows / 2) in
    match t with
    | Down -> 1
    | Up -> -1
    | Half_down -> half
    | Half_up -> -half
    | First | Last -> 0
  ;;
end

let interpret (keys : Key.t list) : Motion.t Content_key.t =
  match keys with
  | [ Ctrl 'd' ] -> Action Half_down
  | [ Ctrl 'u' ] -> Action Half_up
  | [ key ] when Key.equal key (Key.char 'j') -> Action Down
  | [ key ] when Key.equal key (Key.char 'k') -> Action Up
  | [ key ] when Key.equal key (Key.char 'G') -> Action Last
  | [ key ] when Key.equal key (Key.char 'g') -> Prefix
  | [ g; key ] when Key.equal g (Key.char 'g') && Key.equal key (Key.char 'g') ->
    Action First
  | _ -> Unbound
;;

module Selection = struct
  type 'key t =
    { selected : 'key option
    ; index : int
    ; top : int
    }
  [@@deriving sexp_of]

  let empty = { selected = None; index = 0; top = 0 }

  let fit t keys ~equal ~rows =
    let count = List.length keys in
    let index =
      Option.bind t.selected ~f:(fun selected ->
        List.findi keys ~f:(fun _ key -> equal key selected) |> Option.map ~f:fst)
      |> Option.value ~default:(Int.min t.index (Int.max 0 (count - 1)))
    in
    let rows = Int.max 1 rows in
    let top = Int.min t.top (Int.max 0 (count - rows)) in
    let top =
      if index < top then index else if index >= top + rows then index - rows + 1 else top
    in
    { selected = List.nth keys index; index; top }
  ;;

  let select t keys ~equal ~rows index =
    let index = Int.clamp_exn index ~min:0 ~max:(Int.max 0 (List.length keys - 1)) in
    fit { t with selected = None; index } keys ~equal ~rows
  ;;

  let move t keys ~equal ~rows (motion : Motion.t) =
    let t = fit t keys ~equal ~rows in
    let index =
      match motion with
      | First -> 0
      | Last -> List.length keys - 1
      | Down | Up | Half_down | Half_up -> t.index + Motion.delta motion ~rows
    in
    select t keys ~equal ~rows index
  ;;
end

let move_offset top ~total ~rows (motion : Motion.t) =
  let maximum = Int.max 0 (total - rows) in
  match motion with
  | First -> 0
  | Last -> maximum
  | Down | Up | Half_down | Half_up ->
    Int.clamp_exn (top + Motion.delta motion ~rows) ~min:0 ~max:maximum
;;
