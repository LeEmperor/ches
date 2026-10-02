open! Core

type point =
  { x : float
  ; y : float
  }

type t =
  { enabled : bool
  ; current : point array option
  ; target : point array option
  ; velocity : point array
  ; stiffness : float array
  }

let create ~enabled =
  { enabled; current = None; target = None; velocity = [||]; stiffness = [||] }
;;

let enabled t = t.enabled
let active t = Option.is_some t.current

let stopped t =
  { t with current = None; target = None; velocity = [||]; stiffness = [||] }
;;

let set_enabled t enabled =
  if Bool.equal enabled t.enabled then t else stopped { t with enabled }
;;

let quad (x, y) =
  let x = Float.of_int x and y = Float.of_int y in
  [| { x; y }; { x = x +. 1.; y }; { x = x +. 1.; y = y +. 1. }; { x; y = y +. 1. } |]
;;

let equal_position a b =
  match a, b with
  | Some (ax, ay), Some (bx, by) -> ax = bx && ay = by
  | None, None -> true
  | Some _, None | None, Some _ -> false
;;

let center points =
  Array.fold points ~init:{ x = 0.; y = 0. } ~f:(fun sum point ->
    { x = sum.x +. (point.x /. 4.); y = sum.y +. (point.y /. 4.) })
;;

let stiffnesses current target =
  (* As in Smear, the corner nearest the target is the head.  Determining this from the
     geometry (rather than fixed corner indices) is what makes all four directions and
     diagonal movement behave alike. *)
  let target = center target in
  let distances =
    Array.map current ~f:(fun point -> Float.hypot (point.x -. target.x) (point.y -. target.y))
  in
  let minimum = Array.fold distances ~init:Float.infinity ~f:Float.min in
  let maximum = Array.fold distances ~init:Float.neg_infinity ~f:Float.max in
  if Float.(maximum - minimum < 0.000_001)
  then Array.create ~len:4 0.6
  else
    Array.map distances ~f:(fun distance ->
      let trailing = (distance -. minimum) /. (maximum -. minimum) in
      0.6 +. ((0.45 -. 0.6) *. (trailing ** 3.)))
;;

let retarget t ~from ~to_ =
  if not t.enabled || equal_position from to_
  then t
  else (
    match from, to_ with
    | Some from, Some to_ ->
      let current = Option.value t.current ~default:(quad from) in
      let target = quad to_ in
      let velocity =
        if Option.is_some t.current
        then t.velocity
        else
          Array.mapi current ~f:(fun i point ->
            { x = (point.x -. target.(i).x) *. 0.2
            ; y = (point.y -. target.(i).y) *. 0.2
            })
      in
      { t with
        current = Some current
      ; target = Some target
      ; velocity
      ; stiffness = stiffnesses current target
      }
    | None, _ | _, None -> stopped t)
;;

let tick t ~dt =
  if Float.(dt <= 0.)
  then t
  else if Float.(dt > 0.1)
  then
    (* After a suspended or badly delayed UI frame, showing old intermediate positions is
       more distracting than completing the move. *)
    stopped t
  else
    match t.current, t.target with
    | Some current, Some target ->
      let frames = Float.max 0. (Float.min 4. (dt /. 0.017)) in
      (* Smear expresses damping as the fraction removed per frame.  Correct both damping
         and stiffness for elapsed time so a late frame does not change the feel. *)
      let velocity_conservation = 0.15 ** frames in
      let damping_correction = 1. /. (1. +. (2.5 *. velocity_conservation)) in
      let current, velocity =
        Array.mapi current ~f:(fun i point ->
          let target = target.(i) in
          let velocity = t.velocity.(i) in
          let stiffness =
            1. -. ((1. -. (t.stiffness.(i) *. damping_correction)) ** frames)
          in
          let velocity =
            { x = velocity.x +. ((target.x -. point.x) *. stiffness)
            ; y = velocity.y +. ((target.y -. point.y) *. stiffness)
            }
          in
          ( { x = point.x +. velocity.x; y = point.y +. velocity.y }
          , { x = velocity.x *. velocity_conservation
            ; y = velocity.y *. velocity_conservation
            } ))
        |> Array.unzip
      in
      let settled =
        Array.for_alli current ~f:(fun i point ->
          let target = target.(i) and velocity = velocity.(i) in
          Float.(hypot (target.x -. point.x) (target.y -. point.y) < 0.06)
          && Float.(hypot velocity.x velocity.y < 0.025))
      in
      if settled then stopped t
      else { t with current = Some current; velocity }
    | None, None -> t
    | Some _, None | None, Some _ -> stopped t
;;

let cross a b p = ((b.x -. a.x) *. (p.y -. a.y)) -. ((b.y -. a.y) *. (p.x -. a.x))

let contains quad p =
  let signs =
    List.init 4 ~f:(fun i -> cross quad.(i) quad.((i + 1) mod 4) p)
  in
  List.for_all signs ~f:(fun value -> Float.(value >= -.0.001))
  || List.for_all signs ~f:(fun value -> Float.(value <= 0.001))
;;

let cells t ~width ~height =
  match t.current with
  | None -> []
  | Some quad ->
    let bounds coordinate =
      Array.fold quad ~init:(Float.infinity, Float.neg_infinity) ~f:(fun (lo, hi) point ->
        Float.min lo (coordinate point), Float.max hi (coordinate point))
    in
    let x_lo, x_hi = bounds (fun p -> p.x) and y_lo, y_hi = bounds (fun p -> p.y) in
    let lo value = Int.max 0 (Int.of_float value) in
    let hi value limit = Int.min limit (Int.of_float (value +. 1.)) in
    let x0 = lo x_lo and x1 = hi x_hi width and y0 = lo y_lo and y1 = hi y_hi height in
    let cells =
      List.concat_map (List.init (Int.max 0 (y1 - y0)) ~f:(fun y -> y0 + y)) ~f:(fun y ->
        List.filter_map (List.init (Int.max 0 (x1 - x0)) ~f:(fun x -> x0 + x)) ~f:(fun x ->
          Option.some_if (contains quad { x = Float.of_int x +. 0.5; y = Float.of_int y +. 0.5 }) (x, y)))
    in
    (* A very fast, thin cursor can fall between cell centres.  Keep at least one block
       visible rather than flickering out for that frame. *)
    match cells with
    | _ :: _ -> cells
    | [] ->
      let center = center quad in
      let x = Int.of_float (Float.round_down center.x)
      and y = Int.of_float (Float.round_down center.y) in
      if x >= 0 && x < width && y >= 0 && y < height then [ x, y ] else []
;;
