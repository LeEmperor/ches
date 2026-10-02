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

let draw (frame : Frame.t) =
  View.vcat
    (List.map frame.rows ~f:(fun spans -> View.hcat (List.map spans ~f:draw_span)))
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

let app controller ~exit ~dimensions (local_ graph) =
  let model, inject =
    Bonsai.state_machine_with_input
      ~default_model:(Ui_state.create controller)
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
    (app controller)
;;
