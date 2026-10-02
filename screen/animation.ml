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
  }

let create ~enabled = { enabled; current = None; target = None; velocity = [||] }
let enabled t = t.enabled
let active t = Option.is_some t.current

let set_enabled t enabled =
  if Bool.equal enabled t.enabled then t else { enabled; current = None; target = None; velocity = [||] }
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
        else Array.map current ~f:(fun p -> { x = (p.x -. target.(0).x) *. 0.06; y = 0. })
      in
      { t with current = Some current; target = Some target; velocity }
    | None, _ | _, None -> { t with current = None; target = None; velocity = [||] })
;;

let tick t ~dt =
  match t.current, t.target with
  | Some current, Some target ->
    (* These values are tuned from Smear's spring model, but use seconds rather than a
       Neovim timer interval.  The leading edge is deliberately stiffer than the tail. *)
    let frames = Float.max 0.25 (Float.min 3. (dt /. 0.017)) in
    let damping = 0.18 ** frames in
    let current, velocity =
      Array.mapi current ~f:(fun i point ->
        let stiffness = if i = 0 || i = 3 then 0.42 else 0.24 in
        let target = target.(i) in
        let velocity = t.velocity.(i) in
        let velocity =
          { x = (velocity.x +. ((target.x -. point.x) *. stiffness *. frames)) *. damping
          ; y = (velocity.y +. ((target.y -. point.y) *. stiffness *. frames)) *. damping
          }
        in
        { x = point.x +. velocity.x; y = point.y +. velocity.y }, velocity)
      |> Array.unzip
    in
    let settled =
      Array.for_alli current ~f:(fun i point ->
        let target = target.(i) and velocity = velocity.(i) in
        Float.(hypot (target.x -. point.x) (target.y -. point.y) < 0.06)
        && Float.(hypot velocity.x velocity.y < 0.025))
    in
    if settled then { t with current = None; target = None; velocity = [||] }
    else { t with current = Some current; velocity }
  | None, None -> t
  | Some _, None | None, Some _ -> { t with current = None; target = None; velocity = [||] }
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
    List.concat_map (List.init (Int.max 0 (y1 - y0)) ~f:(fun y -> y0 + y)) ~f:(fun y ->
      List.filter_map (List.init (Int.max 0 (x1 - x0)) ~f:(fun x -> x0 + x)) ~f:(fun x ->
        Option.some_if (contains quad { x = Float.of_int x +. 0.5; y = Float.of_int y +. 0.5 }) (x, y)))
;;
