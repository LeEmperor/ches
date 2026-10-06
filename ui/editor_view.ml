open! Core
open Bonsai_term
open Bonsai.Let_syntax
open Ches_screen

let draw_span ?font ~chrome ({ text; width; style } : Frame.Span.t) =
  let attrs = Theme.attrs ~chrome ?font style in
  let view = View.text ~attrs text in
  let drawn = View.width view in
  if drawn = width
  then view
  else if drawn > width
  then View.crop ~r:(drawn - width) view
  else View.hcat [ view; View.rectangle ~attrs ~width:(width - drawn) ~height:1 () ]
;;

let draw_smear ?font (frame : Frame.t) =
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
          :: View.text ~attrs:(Theme.attrs ?font Smear) "█"
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

let draw ?font (frame : Frame.t) =
  let base =
    View.vcat
      (List.map frame.rows ~f:(fun spans ->
         View.hcat (List.map spans ~f:(draw_span ?font ~chrome:frame.chrome))))
  in
  View.zcat [ draw_smear ?font frame; base ]
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

let app ?(smear_enabled = false) ?report ?font controller ~exit ~dimensions (local_ graph) =
  let model, inject =
    Bonsai.state_machine_with_input
      ~default_model:(Ui_state.create ~smear_enabled ?report controller)
      ~apply_action:(fun context input model inputs ->
        match input with
        | Inactive -> model
        | Active ({ Dimensions.width; height }, write_to_tty) ->
          let was_running = not (Ui_state.exited model) in
          let model, status = Ui_state.apply_all model ~width ~height inputs in
          let model, clipboard = Ui_state.take_clipboard model in
          Option.iter clipboard ~f:(fun text ->
            Bonsai.Apply_action_context.schedule_event
              context
              (write_to_tty (Osc52.set_clipboard text)));
          (match status with
           | Exit when was_running ->
             Bonsai.Apply_action_context.schedule_event context (exit ())
           | Exit | Running -> ());
          model)
      (let%arr dimensions
       and write_to_tty = Expert.Write_to_tty.write_string_to_tty graph in
       dimensions, write_to_tty)
      graph
  in
  let get_current_time = Bonsai.Clock.get_current_time graph in
  Bonsai.Edge.on_change
    dimensions
    ~equal:(fun (a : Dimensions.t) b -> a.width = b.width && a.height = b.height)
    ~callback:(let%arr inject in fun _ -> inject [ Ui_state.Input.Resize ])
    graph;
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
    draw ?font frame
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

let run ?font ?report controller =
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
    (app ~smear_enabled:true ?report ?font controller)
;;
