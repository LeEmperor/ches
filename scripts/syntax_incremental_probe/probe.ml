(* Explicit reproducible CPU-stage benchmark. Never run by editor input/tests.
   Automatic GC is included; forced GC only separates benchmark modes. *)
open! Core
open Ches_highlight
module Provider = Ches_highlight_ocaml.Provider

let measure ~incremental ~language source =
  let provider = Provider.create ~language in
  let document = Snapshot.Document_id.create () in
  let highlight = if incremental then Provider.highlight_incremental else Provider.highlight in
  let initial_key = Provider.key provider ~document ~revision:0 in
  ignore (highlight provider ~key:initial_key ~source : Provider.result);
  let total = ref 0. and preparation = ref 0. and parsing = ref 0.
  and querying = ref 0. and normalization = ref 0. in
  for revision = 1 to 20 do
    let source = String.make revision ' ' ^ source in
    let key = Provider.key provider ~document ~revision in
    let start = Stdlib.Sys.time () in
    let result = highlight provider ~key ~source in
    total := !total +. Stdlib.Sys.time () -. start;
    assert (match result.status with Highlighted _ -> true | Plain _ -> false);
    let timings = Option.value_exn (Provider.last_timings provider) in
    preparation := !preparation +. timings.preparation;
    parsing := !parsing +. timings.parsing;
    querying := !querying +. timings.querying;
    normalization := !normalization +. timings.normalization
  done;
  assert (Provider.parse_count provider = 21);
  assert (Provider.incremental_count provider = if incremental then 20 else 0);
  let ms seconds = seconds *. 1000. /. 20. in
  printf "  %s mean CPU ms: total=%.3f prepare=%.3f parse=%.3f query=%.3f normalize=%.3f\n%!"
    (if incremental then "incremental" else "fresh")
    (ms !total) (ms !preparation) (ms !parsing) (ms !querying) (ms !normalization);
  Provider.close provider
;;

let frame source path =
  let text = Ches_core.Text_buffer.of_string source |> Result.map_error
      ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
  let controller = Ches_app.Controller.create
      (Ches_core.Editor.create ~path ~cell_width:Ches_screen.Cell_map.width text) in
  let ui = Ches_screen.Ui_state.create ~smear_enabled:false controller in
  let count = Ches_app.Controller.highlight_parse_count controller in
  let start = Stdlib.Sys.time () in
  for _ = 1 to 100 do
    ignore (Ches_screen.Frame.render ui ~width:100 ~height:30 : Ches_screen.Frame.t)
  done;
  printf "  frame 100x30 mean CPU ms=%.3f (100 renders, no parses)\n%!"
    ((Stdlib.Sys.time () -. start) *. 10.);
  assert (Ches_app.Controller.highlight_parse_count controller = count);
  Ches_app.Controller.close controller
;;

let () =
  List.iter [ Language.Ocaml, "ml", "let f x = \"é\\n\" (* outer (* inner *) *)\n"
            ; Ocaml_interface, "mli", "val f : int -> string (* outer (* inner *) *)\n" ]
    ~f:(fun (language, extension, line) ->
      List.iter [ 10; 1000; 5000 ] ~f:(fun copies ->
        let source = String.concat (List.init copies ~f:(fun _ -> line)) in
        printf "%s %d copies, %d bytes; 20 successive leading-space insertions\n%!"
          extension copies (String.length source);
        List.iter [ false; true ] ~f:(fun incremental ->
          Gc.full_major ();
          measure ~incremental ~language source);
        frame source ("generated." ^ extension)))
;;
