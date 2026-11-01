open! Core

(* What a lane shows on one row (see the .mli's glyphs). *)
module Cell = struct
  type t =
    | Commit
    | Through (** Waits for another commit before and after the row. *)
    | Ends
    | Starts
    | Joins
    | Free
end

(* The glyph of a lane that is not the commit's: [left] when it lies left of the
   commit, [crossed] when a horizontal line runs through it. *)
let glyph (cell : Cell.t) ~left ~crossed =
  match cell with
  | Commit -> "●"
  | Through -> if crossed then "┼" else "│"
  | Ends -> if left then "╰" else "╯"
  | Starts -> if left then "╭" else "╮"
  | Joins -> if left then "├" else "┤"
  | Free -> if crossed then "─" else " "
;;

(* [cells] as characters (one string each), cut to [max_width]. *)
let render ~max_width cells =
  let length = List.length cells in
  if length <= max_width
  then String.concat cells
  else String.concat (List.take cells (Int.max 0 (max_width - 2))) ^ "… "
;;

let rows ?(max_width = 24) commits =
  (* [lanes.(i)]: the commit lane [i] waits for; no free lanes at the right end. *)
  let lanes = ref [||] in
  let seen = Hash_set.create (module String) in
  List.map commits ~f:(fun (id, parents) ->
    let before = !lanes in
    let n = Array.length before in
    (* Duplicate ids: nothing waits for the later ones. *)
    let duplicate = Hash_set.mem seen id in
    Hash_set.add seen id;
    let waits_here i = (not duplicate) && [%equal: string option] before.(i) (Some id) in
    let free_before i = i >= n || Option.is_none before.(i) in
    (* Room for every lane this row can add: the commit's and one per parent. *)
    let size = n + 1 + List.length parents in
    let after = Array.create ~len:size None in
    Array.blit ~src:before ~src_pos:0 ~dst:after ~dst_pos:0 ~len:n;
    let cells = Array.create ~len:size Cell.Free in
    let lane =
      match List.find (List.init n ~f:Fn.id) ~f:waits_here with
      | Some i -> i
      | None ->
        Option.value (List.find (List.init n ~f:Fn.id) ~f:free_before) ~default:n
    in
    (* The next new lane on the right. *)
    let next_new = ref (Int.max n (lane + 1)) in
    cells.(lane) <- Commit;
    for i = 0 to n - 1 do
      if i <> lane && waits_here i
      then (
        cells.(i) <- Ends;
        after.(i) <- None)
    done;
    (match parents with
     | [] -> after.(lane) <- None
     | first :: further ->
       after.(lane) <- Some first;
       List.iter further ~f:(fun parent ->
         let waiting =
           Array.findi after ~f:(fun i waits ->
             i <> lane && [%equal: string option] waits (Some parent))
         in
         match waiting with
         | Some (i, _) ->
           (* A lane started by an earlier parent of this same commit stays a start. *)
           (match cells.(i) with
            | Starts -> ()
            | _ -> cells.(i) <- Joins)
         | None ->
           let i =
             match
               List.find (List.init n ~f:Fn.id) ~f:(fun i ->
                 i <> lane && free_before i && Option.is_none after.(i))
             with
             | Some i -> i
             | None ->
               let i = !next_new in
               incr next_new;
               i
           in
           cells.(i) <- Starts;
           after.(i) <- Some parent));
    for i = 0 to n - 1 do
      match cells.(i) with
      | Free when Option.is_some before.(i) -> cells.(i) <- Through
      | _ -> ()
    done;
    let in_use i =
      i = lane || Option.is_some after.(i) || (i < n && Option.is_some before.(i))
    in
    let width =
      1 + Option.value_exn (List.find (List.rev (List.init size ~f:Fn.id)) ~f:in_use)
    in
    (* The horizontal line: from the commit to the farthest lane it ends, starts or
       joins on either side. *)
    let connected =
      List.filter (List.init width ~f:Fn.id) ~f:(fun i ->
        match cells.(i) with
        | Ends | Starts | Joins -> true
        | Commit | Through | Free -> false)
    in
    let low = List.fold connected ~init:lane ~f:Int.min in
    let high = List.fold connected ~init:lane ~f:Int.max in
    let row =
      List.concat_map (List.init width ~f:Fn.id) ~f:(fun i ->
        [ glyph cells.(i) ~left:(i < lane) ~crossed:(low < i && i < high)
        ; (if low <= i && i < high then "─" else " ")
        ])
    in
    let last_used =
      Array.foldi after ~init:(-1) ~f:(fun i last waits ->
        if Option.is_some waits then i else last)
    in
    lanes := Array.sub after ~pos:0 ~len:(last_used + 1);
    render ~max_width row)
;;
