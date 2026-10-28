open! Core
module B = Text_buffer

module Side = struct
  type t =
    | Upper
    | Lower
    | Both
    | Base
  [@@deriving sexp_of, equal, enumerate]

  let to_string = function
    | Upper -> "upper"
    | Lower -> "lower"
    | Both -> "both"
    | Base -> "base"
  ;;
end

module Region = struct
  type t =
    { start : int
    ; base : int option
    ; separator : int
    ; stop : int
    ; upper_label : string
    ; base_label : string
    ; lower_label : string
    }
  [@@deriving sexp_of, equal]

  (* The lines strictly between [first] and [last]. *)
  let between first last = List.range (first + 1) last

  let lines t (side : Side.t) =
    let upper = between t.start (Option.value t.base ~default:t.separator) in
    let lower = between t.separator t.stop in
    match side with
    | Upper -> Some upper
    | Lower -> Some lower
    | Both -> Some (upper @ lower)
    | Base -> Option.map t.base ~f:(fun base -> between base t.separator)
  ;;
end

type marker =
  | Start of string
  | Base of string
  | Separator
  | End of string

let size = 7

(* The marker [line] is, if any. Only a line starting with a marker character is
   copied out. *)
let marker text line =
  let start = B.line_start text line in
  if B.line_end text line - start < size
  then None
  else (
    match Uchar.to_char (B.uchar_at text start) with
    | Some (('<' | '|' | '=' | '>') as c) ->
      let s = B.line_text text line in
      if not (String.is_prefix s ~prefix:(String.make size c))
      then None
      else (
        let rest = String.drop_prefix s size in
        match c with
        | '=' -> Option.some_if (String.is_empty rest) Separator
        | _ when not (String.is_empty rest || Char.equal rest.[0] ' ') -> None
        | _ ->
          let label = String.drop_prefix rest 1 in
          (match c with
           | '<' -> Some (Start label)
           | '|' -> Some (Base label)
           | _ -> Some (End label)))
    | Some _ | None -> None)
;;

(* How far into a region the scan is. *)
type state =
  | Outside
  | Upper of { start : int; label : string }
  | Base_part of { start : int; label : string; base : int; base_label : string }
  | Lower of
      { start : int
      ; label : string
      ; base : (int * string) option
      ; separator : int
      }

let regions text =
  let rec scan line state found =
    if line >= B.line_count text
    then List.rev found
    else (
      let next state = scan (line + 1) state found in
      match marker text line, state with
      | None, _ -> next state
      | Some (Start label), _ -> next (Upper { start = line; label })
      | Some (Base base_label), Upper { start; label } ->
        next (Base_part { start; label; base = line; base_label })
      | Some Separator, Upper { start; label } ->
        next (Lower { start; label; base = None; separator = line })
      | Some Separator, Base_part { start; label; base; base_label } ->
        next (Lower { start; label; base = Some (base, base_label); separator = line })
      | Some (End lower_label), Lower { start; label; base; separator } ->
        let region =
          { Region.start
          ; base = Option.map base ~f:fst
          ; separator
          ; stop = line
          ; upper_label = label
          ; base_label = Option.value_map base ~default:"" ~f:snd
          ; lower_label
          }
        in
        scan (line + 1) Outside (region :: found)
      (* Outside a region these are ordinary text; inside one they are out of order,
         which abandons it. *)
      | Some (Base _ | Separator | End _), _ -> next Outside)
  in
  scan 0 Outside []
;;

let region_at text ~line =
  List.find (regions text) ~f:(fun (region : Region.t) ->
    region.start <= line && line <= region.stop)
;;
