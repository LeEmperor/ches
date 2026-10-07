(* Drives Ui_state with a diagnostic source the way Editor_view does: requests are
   taken after each transition and sent, and pending events are applied as one
   transition. Time is simulated, so delays are exact. *)
open! Core
open! Async
open Ches_screen
open Ches_source
module Controller = Ches_app.Controller

let width = 120
let height = 24

type t =
  { time : Time_source.Read_write.t
  ; mutable source : Source.t
  ; mutable ui : Ui_state.t
  ; directory : string
  }

let create_time () = Time_source.create ~now:Time_ns.epoch ()

(* A document [a.ml] with [text] in a fresh directory, and [source] for it. *)
let create ?(text = "let x = 1\n") ~source () =
  let directory = Core_unix.mkdtemp (Filename.concat (Filename.temp_dir_name) "ches-source") in
  let path = Filename.concat directory "a.ml" in
  Out_channel.write_all path ~data:text;
  let controller =
    Controller.open_file ~cell_width:Cell_map.width path |> Or_error.ok_exn
  in
  let time = create_time () in
  { time
  ; source = source ~time:(Time_source.read_only time) ~root:directory
  ; ui = Ui_state.create ~tiles_visible:false ~source_attached:true controller
  ; directory
  }
;;

let send_requests t =
  let ui, requests = Ui_state.take_source_requests t.ui in
  t.ui <- ui;
  List.iter requests ~f:(Source.send t.source)
;;

let apply t inputs =
  let ui, (_ : Controller.Status.t) = Ui_state.apply_all t.ui ~width ~height inputs in
  t.ui <- ui;
  send_requests t
;;

(* Every pending event, one bounded batch per transition; the batch sizes. *)
let deliver t =
  let rec loop sizes =
    match Source.poll t.source with
    | [] -> List.rev sizes
    | events ->
      apply t (List.map events ~f:(fun event -> Ui_state.Input.Source event));
      loop (List.length events :: sizes)
  in
  loop []
;;

let advance t ms =
  let%map () =
    Time_source.advance_by_alarms_by t.time (Time_ns.Span.of_int_ms ms)
  in
  ignore (deliver t : int list)
;;

let keys t s =
  apply
    t
    (List.map (Key_notation.keys s) ~f:(function
       | Key key -> Ui_state.Input.Key key
       | Paste _ -> assert false))
;;

let feedback t = Controller.feedback (Ui_state.controller t.ui)
let editor t = Controller.editor (Ui_state.controller t.ui)

(* Paths relative to the test's directory, which differs per run. *)
let relative t s =
  String.substr_replace_all s ~pattern:(t.directory ^ "/") ~with_:""
  |> String.substr_replace_all ~pattern:t.directory ~with_:"<root>"
;;

(* The problems view's rows: [~] marks dimmed findings. *)
let rows t =
  let document = Problems_tile.document (Ui_state.problems_tile t.ui) (editor t) in
  let entries = Problems_tile.entries (Ui_state.problems_tile t.ui) (feedback t) ~document in
  if List.is_empty entries then print_endline "(no rows)";
  List.iter entries ~f:(fun (row : Problems.Row.t) ->
    let stale =
      match row.kind with
      | Finding { stale = true; _ } -> "~"
      | Finding _ | Problem _ -> " "
    in
    printf "%s %s\n" stale (relative t (Problems.description row)))
;;

let status t =
  print_endline
    (Option.value_map (Ui_state.message t.ui) ~default:"(no message)" ~f:(fun m ->
       relative t m.text))
;;
