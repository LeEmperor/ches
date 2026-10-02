open! Core
open Bonsai_term
open Bonsai.Let_syntax
open Ches_screen

let draw_span ({ text; width; style } : Frame.Span.t) =
  let attrs = Theme.attrs style in
  let view = View.text ~attrs text in
  let drawn = View.width view in
  if drawn = width
  then view
  else if drawn > width
  then View.crop ~r:(drawn - width) view
  else View.hcat [ view; View.rectangle ~attrs ~width:(width - drawn) ~height:1 () ]
;;

let draw_smear (frame : Frame.t) =
  let cells = List.sort frame.smear ~compare:(fun (x1, y1) (x2, y2) -> [%compare: int * int] (y1, x1) (y2, x2)) in
  match cells with
  | [] -> View.none
  | _ ->
    let rows = List.group cells ~break:(fun (_, y1) (_, y2) -> y1 <> y2) in
    let first_y = snd (List.hd_exn cells) in
    let row_view cells =
      let rec loop previous_x = function
        | [] -> []
        | (x, _) :: rest ->
          let gap = Int.max 0 (x - previous_x) in
          View.transparent_rectangle ~width:gap ~height:1
          :: View.text ~attrs:(Theme.attrs Smear) "█"
          :: loop (x + 1) rest
      in
      View.hcat (loop 0 cells)
    in
    View.vcat
      (View.transparent_rectangle ~width:0 ~height:first_y
       :: List.concat_mapi rows ~f:(fun i row ->
         let y = snd (List.hd_exn row) in
         let previous_y = if i = 0 then first_y else snd (List.hd_exn (List.nth_exn rows (i - 1))) in
         View.transparent_rectangle ~width:0 ~height:(Int.max 0 (y - previous_y - 1)) :: [ row_view row ]))
;;

let draw (frame : Frame.t) =
  let base =
    View.vcat
      (List.map frame.rows ~f:(fun spans -> View.hcat (List.map spans ~f:draw_span)))
  in
  View.zcat [ draw_smear frame; base ]
;;

let cursor (frame : Frame.t) : Cursor.t option =
  Option.map frame.cursor ~f:(fun { x; y; shape } ->
    { Cursor.position = { x; y }
    ; kind =
        (match shape with
         | Block -> Block
         | Bar -> Bar)
    })
;;

let app ?(smear_enabled = false) controller ~exit ~dimensions (local_ graph) =
  let model, inject =
    Bonsai.state_machine_with_input
      ~default_model:(Ui_state.create ~smear_enabled controller)
      ~apply_action:(fun context dimensions model inputs ->
        match dimensions with
        | Inactive -> model
        | Active { Dimensions.width; height } ->
          let was_running = not (Ui_state.exited model) in
          let model, status = Ui_state.apply_all model ~width ~height inputs in
          (match status with
           | Exit when was_running ->
             Bonsai.Apply_action_context.schedule_event context (exit ())
           | Exit | Running -> ());
          model)
      dimensions
      graph
  in
  let get_current_time = Bonsai.Clock.get_current_time graph in
  let () =
    Bonsai.Clock.every
      ~when_to_start_next_effect:`Every_multiple_of_period_non_blocking
      ~trigger_on_activate:true
      (Bonsai.return (Time_ns.Span.of_ms 17.))
      (let%arr inject
       and model
       and get_current_time in
       if Animation.active (Ui_state.animation model)
       then (
         let%bind.Effect now = get_current_time in
         inject [ Ui_state.Input.Animation_tick now ])
       else Effect.Ignore)
      graph
  in
  let frame =
    let%arr model
    and { Dimensions.width; height } = dimensions in
    Frame.render model ~width ~height
  in
  let set_cursor = Effect.set_cursor graph in
  Bonsai.Edge.after_display
    (let%arr frame and set_cursor in
     set_cursor (cursor frame))
    graph;
  let view =
    let%arr frame in
    draw frame
  in
  let handler =
    let%arr inject in
    fun event ->
      match Terminal_input.inputs event with
      | [] -> Effect.Ignore
      | inputs -> inject inputs
  in
  ~view, ~handler
;;

let run controller =
  (* Terminating signals shut down through Async, whose shutdown handlers restore the
     terminal; the default action would leave it in raw mode on the alternate screen.
     Unsaved changes are discarded. *)
  Async.Signal.handle
    [ Async.Signal.term; Async.Signal.hup ]
    ~f:(fun (_ : Signal.t) -> Async.shutdown 1);
  Bonsai_term.start_with_exit
    ~dispose:true
    ~mouse:No_mouse_events
    ~bpaste:true
    (app ~smear_enabled:true controller)
;;
