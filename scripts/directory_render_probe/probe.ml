open! Core
open Ches_core
open Ches_app
open Ches_screen

let measure label iterations f =
  let start = Stdlib.Sys.time () in
  for _ = 1 to iterations do f () done;
  printf "%s: %.3f ms CPU/op (%d iterations)\n%!" label
    ((Stdlib.Sys.time () -. start) *. 1000. /. Float.of_int iterations) iterations
;;

let () =
  let argv = Sys.get_argv () in
  let path = if Array.length argv > 1 then argv.(1) else "/home/wayne/devel/neovim/src/nvim" in
  let ui = Ui_state.create ~tiles_visible:false ~smear_enabled:false
    (Startup.open_path ~cell_width:Cell_map.width path |> Or_error.ok_exn) in
  Exn.protect ~finally:(fun () -> Session.dispose (Ui_state.session ui)) ~f:(fun () ->
    let d = Session.directory_buffer (Ui_state.session ui) |> Option.value_exn in
    printf "%s: %d entries, 160x48\n%!" path (List.length d.entries);
    measure "first Frame.render" 1 (fun () -> ignore (Frame.render ui ~width:160 ~height:48));
    measure "repeated Frame.render" 10 (fun () -> ignore (Frame.render ui ~width:160 ~height:48));
    List.iter [250; 500; 1000] ~f:(fun count ->
      let entries = List.init count ~f:(fun i ->
        { Directory_identity.Entry.id = i + 1; name = sprintf "entry-%04d" i; kind = File }) in
      let baseline = Directory_identity.create entries |> Or_error.ok_exn in
      let text = Directory_identity.text ~scope:"probe" baseline in
      measure (sprintf "parse %d hidden rows" count) 3 (fun () ->
        ignore (Directory_identity.parse baseline text |> Or_error.ok_exn))))
;;
