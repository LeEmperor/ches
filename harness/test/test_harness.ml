open! Core
module Vcd = Ches_harness.Vcd
module Ui = Ches_screen.Ui_state

let header = "$timescale 10 ps $end\n$scope module top $end\n\
  $var wire 1 ! clock $end\n$var wire 4 # data [3:0] $end\n\
  $var wire 4 # alias [3:0] $end\n$upscope $end\n$enddefinitions $end\n"
let source = header ^ "$dumpvars\n0!\nbx #\n$end\n#5\n1!\nb10xz #\n#10\n0!\nbz #\n#30\n"

let%test_unit "VCD keeps scales, aliases, x/z extension, exact boundaries and last time" =
  let wave = Vcd.parse source |> Or_error.ok_exn in
  assert (String.equal wave.timescale "10ps");
  assert (wave.last = 30);
  assert (Array.length wave.signals = 3);
  let data = wave.signals.(1) in
  assert (String.equal data.name "top.data[3:0]");
  List.iter [0, "xxxx"; 4, "xxxx"; 5, "10xz"; 9, "10xz"; 10, "zzzz"; 30, "zzzz"]
    ~f:(fun (at, expected) -> assert (String.equal expected (Vcd.value_at data at)));
  assert ([%equal: (int * string) array] data.changes wave.signals.(2).changes);
  assert (phys_equal data.changes wave.signals.(2).changes);
  let same_tick = Vcd.parse (header ^ "#5\nb1 #\nb0 #\n") |> Or_error.ok_exn in
  assert (String.equal (Vcd.value_at same_tick.signals.(1) 4) "xxxx");
  assert (String.equal (Vcd.value_at same_tick.signals.(1) 5) "0000")
;;

let%test_unit "unsupported or misleading VCDs fail explicitly" =
  List.iter
    [ "$enddefinitions $end\n"
    ; "$timescale 2 ns $end\n$enddefinitions $end\n"
    ; String.substr_replace_all header ~pattern:"wire 1" ~with_:"real 1"
    ; header ^ "#5\n1!\n#4\n0!"
    ; header ^ "#1000000000001\n"
    ; header ^ "r1.5 !\n"
    ; header ^ "$dumpoff\n0!\n$end"
    ; header ^ "b10101 #\n"
    ; header ^ "1unknown\n"
    ; "$timescale 1ns $end\n$var wire 2 ! a $end\n$var wire 1 ! b $end\n$enddefinitions $end"
    ] ~f:(fun text -> assert (Result.is_error (Vcd.parse text)))
;;

let%test_unit "JSON protocol accepts nonzero run results, rejects CLI errors and escaping scratch entries" =
  let open Ches_harness.Protocol in
  let failed = {|{"run_id":"failed-run","status":"failed","exit_code":1,"project_root":"/scratch/demo","log_path":"/scratch/demo/run.log","artifacts":[]}|} in
  (match parse failed |> Or_error.ok_exn with
   | Finished run -> assert (run.exit_code = 1 && String.equal run.run_id "failed-run")
   | _ -> assert false);
  assert (Result.is_error (parse {|{"status":"error","error":"missing tool"}|}));
  assert (Result.is_error (parse {|{"root":"/scratch","entry_file":"../outside"}|}));
  match parse {|{"root":"/scratch/with spaces","entry_file":"design.ml","actions":["run"],"language":"ocaml"}|} |> Or_error.ok_exn with
  | Created { entry; _ } -> assert (String.equal entry "/scratch/with spaces/design.ml")
  | _ -> assert false
;;

let width = 120 and height = 26
let keys text = String.to_list text |> List.map ~f:(fun c -> Ui.Input.Key (Ches_input.Key.char c))
let apply t keys = Ui.apply_all t ~width ~height keys |> fst
let palette t title = apply t (keys (" cc" ^ title) @ [Ui.Input.Key Enter])
let initial () =
  let text = Ches_core.Text_buffer.of_string "ORIGINAL BUFFER"
    |> Result.map_error ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
  Ui.create (Ches_app.Controller.create (Ches_core.Editor.create
    ~path:"/tmp/original.txt" ~cell_width:Ches_screen.Cell_map.width text))
;;

let%test_unit "palette queues exactly once, busy guard and dirty snapshot preserve editor" =
  let original = initial () in
  let started = palette original "Quick-Harness: New SV scratch" in
  let drained, requests = Ui.take_harness_requests started in
  assert (List.length requests = 1 && String.equal (List.hd_exn requests).action "new-sv");
  let busy = palette drained "Quick-Harness: Run harness" in
  assert (List.is_empty (snd (Ui.take_harness_requests busy)));
  let dirty = apply original (keys "iUNSAVED" @ [Ui.Input.Key Escape]) in
  let rejected = palette dirty "Quick-Harness: Run harness" in
  let _, requests = Ui.take_harness_requests rejected in
  assert (List.mem (List.hd_exn requests).dirty "/tmp/original.txt" ~equal:String.equal);
  assert (String.is_substring (Ches_core.Text_buffer.to_string
    (Ches_core.Editor.text (Ches_app.Controller.editor (Ui.controller rejected)))) ~substring:"UNSAVED")
;;

let%test_unit "native waveform frame, navigation, zoom, scroll, resize and close preserve document" =
  let run : Ches_harness.Protocol.run =
    { run_id = "current-run-123"; status = "success"; exit_code = 0
    ; project_root = "/scratch/project"; log_path = "/scratch/project/run.log"
    ; waveform = Some "/scratch/project/wave.vcd" } in
  let wave = Vcd.parse source |> Or_error.ok_exn in
  let original = initial () in
  let opened = Ui.receive_harness original ~width ~height ~request:"latest"
    (Ok (Finished run, Some (Ok wave))) in
  assert (Ches_tile.View_id.equal (Ui.focused_view opened ~width ~height) Ches_screen.Waveform_tile.id);
  let image t = Ches_screen.Frame.render t ~width ~height |> Ches_screen.Frame.to_string in
  List.iter ["Quick-Harness waveform"; "current-run-123"; "top.data[3:0]"; "xxxx"; "10ps/tick"]
    ~f:(fun substring -> assert (String.is_substring (image opened) ~substring));
  let moved = apply opened (keys "lllll") in
  assert (String.is_substring (image moved) ~substring:"10xz");
  let zoomed = apply moved (keys "-]0+jk") in
  assert (Option.is_some (Ui.waveform zoomed));
  let tiny = Ui.apply_all zoomed ~width:10 ~height:3 [Ui.Input.Resize] |> fst in
  ignore (Ches_screen.Frame.render tiny ~width:10 ~height:3);
  let restored = Ui.apply_all tiny ~width ~height [Ui.Input.Resize] |> fst in
  let closed = apply restored (keys "q") in
  assert (Option.is_none (Ui.waveform closed));
  assert (String.is_substring (image closed) ~substring:"ORIGINAL BUFFER");
  assert (not (Ches_core.Editor.is_dirty (Ches_app.Controller.editor (Ui.controller closed))))
;;
