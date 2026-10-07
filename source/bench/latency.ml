(* Async is single-threaded: a key waits for any source batch already running, so the
   worst key-to-frame delay during a burst is about one key turn plus one batch turn.
   This times both headlessly, as Editor_view runs them: Ui_state.apply_all, then
   Frame.render. Terminal output is not included. *)
open! Core
open Ches_core
open Ches_screen
module Source = Ches_source.Source
module Synthetic = Ches_source.Synthetic
module Key = Ches_input.Key

let width = 160
let height = 48
let samples = 200

let percentile sorted p =
  let n = Array.length sorted in
  sorted.(Int.min (n - 1) (Float.iround_down_exn (p *. Float.of_int n)))
;;

let time f =
  let start = Time_ns.now () in
  f ();
  Time_ns.Span.to_us (Time_ns.diff (Time_ns.now ()) start)
;;

let report name spans =
  let sorted = Array.of_list spans in
  Array.sort sorted ~compare:Float.compare;
  printf
    "%-44s median %8.0f us   p99 %8.0f us   max %8.0f us\n"
    name
    (percentile sorted 0.5)
    (percentile sorted 0.99)
    sorted.(Array.length sorted - 1)
;;

let document_lines = 2000

let create ~problems_visible =
  let text =
    String.concat
      (List.init document_lines ~f:(fun i -> sprintf "let value_%d = %d (* filler *)\n" i i))
    |> Text_buffer.of_string
    |> Result.ok
    |> Option.value_exn
  in
  let controller =
    Ches_app.Controller.create (Editor.create ~path:"a.ml" ~cell_width:Cell_map.width text)
  in
  let ui = Ui_state.create ~source_attached:true controller in
  let ui, _ = Ui_state.apply_all ui ~width ~height (List.map [ 'i' ] ~f:(fun c -> Ui_state.Input.Key (Key.char c))) in
  if problems_visible
  then (
    (* Leave Insert to toggle, then return to it. *)
    let keys = [ Key.Escape; Key.char ' '; Key.char 'v'; Key.char 'b'; Key.char 'i' ] in
    fst (Ui_state.apply_all ui ~width ~height (List.map keys ~f:(fun k -> Ui_state.Input.Key k))))
  else ui
;;

(* A burst: [snapshots] versioned snapshots over [resources] files, plus one per round
   for the open document, each with [findings] findings. *)
let burst ~snapshots ~resources ~findings =
  let others = Synthetic.Script.burst ~source:"lsp" ~snapshots ~resources ~findings in
  let open_file =
    List.init (snapshots / resources) ~f:(fun i ->
      Ches_error.Source_event.Diagnostics
        { source = "lsp"
        ; resource = "a.ml"
        ; revision = None
        ; findings =
            List.init findings ~f:(fun j : Ches_error.Error.Diagnostics.Finding.t ->
              { severity = Warning
              ; message = sprintf "open file finding %d/%d" j i
              ; location = Some { line = 1 + (j * 7 % document_lines); column = 1 }
              })
        })
  in
  others @ open_file
;;

let key_turns ui =
  let ui = ref ui in
  List.init samples ~f:(fun i ->
    time (fun () ->
      let c = if i % 2 = 0 then 'a' else 'b' in
      let next, _ =
        Ui_state.apply_all !ui ~width ~height [ Key (Key.char c) ]
      in
      ignore (Frame.render next ~width ~height : Frame.t);
      ui := next))
  , !ui
;;

let run_scenario ~problems_visible ~snapshots ~resources ~findings =
  let label =
    sprintf
      "%d snapshots x %d findings over %d files, problems %s"
      snapshots
      findings
      (resources + 1)
      (if problems_visible then "shown" else "hidden")
  in
  print_endline label;
  let ui = create ~problems_visible in
  let quiet, ui = key_turns ui in
  report "  key turn + render, no burst" quiet;
  (* Insert holds lists for the open document; leave Insert so the batch applies. *)
  let ui, _ = Ui_state.apply_all ui ~width ~height [ Key Escape ] in
  let events = burst ~snapshots ~resources ~findings in
  let source =
    Synthetic.Script.play (List.map events ~f:(fun e -> Synthetic.Script.Emit e))
  in
  let ui = ref ui in
  let batches = ref [] in
  let rec drain () =
    match Source.poll source with
    | [] -> ()
    | events ->
      batches
      := time (fun () ->
           let next, _ =
             Ui_state.apply_all
               !ui
               ~width
               ~height
               (List.map events ~f:(fun e -> Ui_state.Input.Source e))
           in
           ignore (Frame.render next ~width ~height : Frame.t);
           ui := next)
         :: !batches;
      drain ()
  in
  drain ();
  printf
    "  coalesced %d of %d snapshots into %d batches\n"
    (Source.dropped source)
    (List.length events)
    (List.length !batches);
  report "  batch turn + render (per batch)" !batches;
  let ui, _ = Ui_state.apply_all !ui ~width ~height [ Key (Key.char 'A') ] in
  let loaded, _ = key_turns ui in
  report "  key turn + render, standing findings" loaded;
  print_endline ""
;;

let () =
  List.iter [ false; true ] ~f:(fun problems_visible ->
    run_scenario ~problems_visible ~snapshots:1000 ~resources:100 ~findings:50)
;;
