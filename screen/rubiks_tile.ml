open! Core

let id = Ches_tile.View_id.of_string "rubiks"
let spec = { (Ches_tile.Spec.read_only id ~title:"Rubik's") with accepts_text = true }

(* Random-move practice scrambles, not WCA random-state scrambles. Avoid
   repeated faces and redundant runs of three moves along the same axis. *)
let generate random =
  let faces = [| "U"; "D"; "R"; "L"; "F"; "B" |] in
  let suffixes = [| ""; "'"; "2" |] in
  let rec loop remaining previous before moves =
    if remaining = 0 then String.concat ~sep:" " (List.rev moves)
    else
      let face = Random.State.int random 6 in
      if face = previous || (face / 2 = previous / 2 && previous / 2 = before / 2)
      then loop remaining previous before moves
      else loop (remaining - 1) face previous
          ((faces.(face) ^ suffixes.(Random.State.int random 3)) :: moves)
  in
  loop 20 (-10) (-20) []
;;

type solve = { scramble : string; seconds : float }
type t =
  { scramble : string
  ; started : Time_ns.t option
  ; now : Time_ns.t
  ; solves : solve list
  }

let random = lazy (
  if am_testing then Random.State.make [| 42 |]
  else Random.State.make_self_init ())
let fresh () = generate (Lazy.force random)
let create () = { scramble = fresh (); started = None; now = Time_ns.epoch; solves = [] }
let running t = Option.is_some t.started
let cancel t = { t with started = None }
let tick t now = { t with now }
let elapsed t = Option.value_map t.started ~default:0. ~f:(fun start ->
    Float.max 0. (Time_ns.Span.to_sec (Time_ns.diff t.now start)))
let space t ~now =
  match t.started with
  | None -> { t with started = Some now; now }
  | Some _ ->
    let seconds = elapsed (tick t now) in
    { scramble = fresh (); started = None; now
    ; solves = List.take ({ scramble = t.scramble; seconds } :: t.solves) 100 }
;;

type action = Space | Next
let interpret = function
  | [ key ] when Ches_input.Key.equal key (Ches_input.Key.char ' ') -> Ches_tile.Content_key.Action Space
  | [ key ] when Ches_input.Key.equal key (Ches_input.Key.char 'n') -> Action Next
  | _ -> Unbound
;;
let perform t = function
  | Space -> space t ~now:(Time_ns.now ())
  | Next -> if running t then t else { t with scramble = fresh () }
;;

let render t ~focused ~width ~rows : Tile_shell.Content.t =
  let time =
    if running t then sprintf "Running: %.2f" (elapsed t)
    else match t.solves with
      | [] -> "Ready: 0.00"
      | solve :: _ -> sprintf "Last: %.2f" solve.seconds
  in
  let scramble_lines =
    let rec wrap words line lines =
      match words with
      | [] -> List.rev (line :: lines)
      | word :: rest ->
        let next = if String.is_empty line then word else line ^ " " ^ word in
        if String.length next > Int.max 1 width && not (String.is_empty line)
        then wrap words "" (line :: lines)
        else wrap rest next lines
    in
    wrap (String.split t.scramble ~on:' ') "" []
  in
  let stats = match t.solves with
    | [] -> "No solves yet"
    | solves -> sprintf "%d solves | best %.2f | mean %.2f"
        (List.length solves)
        (List.fold solves ~init:Float.infinity ~f:(fun best s -> Float.min best s.seconds))
        (List.sum (module Float) solves ~f:(fun s -> s.seconds) /. Float.of_int (List.length solves))
  in
  { title = "Rubik's 3x3 (practice)"
  ; footer = Some (Tile_shell.Label.hint
      (if focused then "Space start/stop | n next | Esc return" else "Space v U: focus"))
  ; body = List.take (time :: scramble_lines @ [ stats ]) (Int.max 0 rows)
      |> List.map ~f:(fun text -> Tile_text.row Status text ~width)
  }
;;
