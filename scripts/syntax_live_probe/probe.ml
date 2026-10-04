(* Explicit full-parse controller latency observation. No benchmarks or GC work
   run in the editor. Input latency includes text-buffer/editor work, not rendering. *)
open Ches_core
open Ches_input
open Ches_app

let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    really_input_string channel (in_channel_length channel))
;;

let feed controller key =
  let controller, _, _ = Controller.handle_input controller (Keymap.Input.Key key) in
  controller
;;

let check controller =
  match Controller.highlight_status controller with
  | Some (Highlighted _) -> ()
  | Some (Plain _) | None -> failwith "provider did not highlight benchmark source"
;;

let measure path source =
  let text =
    match Text_buffer.of_string source with
    | Ok text -> text
    | Error error -> failwith (Text_buffer.Invalid_text.to_string_hum error)
  in
  let started = Unix.gettimeofday () in
  let controller = Controller.create (Editor.create ~path ~cell_width:(fun _ -> 1) text) in
  let initial_ms = (Unix.gettimeofday () -. started) *. 1000. in
  if Controller.highlight_parse_count controller <> 1 then failwith "missing initial parse";
  check controller;
  let controller = ref (feed controller (Key.char 'i')) in
  let elapsed = ref [] in
  for _ = 1 to 20 do
    let started = Unix.gettimeofday () in
    controller := feed !controller (Key.char ' ');
    elapsed := (Unix.gettimeofday () -. started) *. 1000. :: !elapsed;
    check !controller
  done;
  if Controller.highlight_parse_count !controller <> 21 then failwith "missing edit parses";
  let before = Controller.highlight_parse_count !controller in
  controller := feed !controller Key.Escape;
  for _ = 1 to 100 do
    controller := feed !controller (Key.char 'l')
  done;
  if Controller.highlight_parse_count !controller <> before then failwith "parsing on movement";
  let spans = Ches_highlight.Snapshot.ranges (snd (Controller.highlights !controller)) |> List.length in
  let mean = List.fold_left ( +. ) 0. !elapsed /. 20. in
  let max_ms = List.fold_left Float.max 0. !elapsed in
  Printf.printf "%s: %d bytes, %d spans; initial %.3f ms; 20 edits mean %.3f ms, max %.3f ms; 100 moves: no parses\n%!"
    path (String.length source) spans initial_ms mean max_ms;
  Controller.close !controller
;;

let () =
  List.iter (fun path -> measure path (read path))
    [ "highlight_ocaml/provider.ml"; "core/editor.ml"; "core/text_buffer.mli" ];
  let line = "let f x = \"é\\n\" (* outer (* inner *) *)\n" in
  measure "generated-large.ml" (String.concat "" (List.init 5000 (fun _ -> line)))
;;
