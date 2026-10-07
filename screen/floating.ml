open! Core

module Size = struct
  type t =
    { width : int
    ; height : int
    }
  [@@deriving sexp_of, equal]
end

let place ~(bounds : Geometry.Rect.t) ~(preferred : Size.t) ~(minimum : Size.t) =
  let axis extent preferred minimum =
    let extent = Int.max 0 extent in
    let minimum = Int.max 1 minimum in
    if extent < minimum
    then None
    else (
      (* The margin is optional, but the minimum is not. Decide per axis so a
         short terminal can still retain its horizontal breathing room. *)
      let available = if extent - minimum >= 2 then extent - 2 else extent in
      let size = Int.min available (Int.max minimum preferred) in
      Some ((extent - size) / 2, size))
  in
  match
    axis bounds.width preferred.width minimum.width,
    axis bounds.height preferred.height minimum.height
  with
  | Some (x, width), Some (y, height) ->
    Some { Geometry.Rect.x = bounds.x + x; y = bounds.y + y; width; height }
  | _ -> None
;;

let layout ~bounds ~preferred ~minimum ~policy =
  Option.map (place ~bounds ~preferred ~minimum) ~f:(Tile_shell.layout policy)
;;
