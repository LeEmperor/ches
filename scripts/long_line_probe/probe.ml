open! Core
open Ches_core
open Ches_app
open Ches_screen

let measure label n f =
  let alloc = Gc.allocated_bytes () in
  let start = Stdlib.Sys.time () in
  for _ = 1 to n do f () done;
  printf "%s: %.3f ms CPU/op, %.0f allocated bytes/op (%d samples)\n%!"
    label ((Stdlib.Sys.time () -. start) *. 1000. /. Float.of_int n)
    ((Gc.allocated_bytes () -. alloc) /. Float.of_int n) n
;;

let () =
  List.iter [1000; 10_000; 100_000] ~f:(fun bytes ->
    let text = Text_buffer.of_string (String.make bytes 'x') |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
    let editor = Editor.create ~path:"long.txt" ~cell_width:Cell_map.width text in
    let ui = Ui_state.create ~tiles_visible:false ~smear_enabled:false (Controller.create editor) in
    let render ui () = ignore (Frame.render ui ~width:160 ~height:48) in
    measure (sprintf "%d left first render" bytes) 1 (render ui);
    measure (sprintf "%d left warm render" bytes) 100 (render ui);
    let right = ref editor in
    measure (sprintf "%d first right navigation" bytes) 1 (fun () ->
      right := Editor.go_to_display_position editor ~line:1 ~column:bytes |> Or_error.ok_exn);
    let ui = Ui_state.create ~tiles_visible:false ~smear_enabled:false (Controller.create !right) in
    measure (sprintf "%d right first render" bytes) 1 (render ui);
    measure (sprintf "%d right warm render" bytes) 100 (render ui);
    measure (sprintf "%d warm adjacent navigation" bytes) 100 (fun () ->
      ignore (Editor.go_to_display_position !right ~line:1 ~column:(bytes - 1) |> Or_error.ok_exn)))
;;
