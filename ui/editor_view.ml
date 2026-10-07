open! Core
open Bonsai_term
open Bonsai.Let_syntax
open Ches_screen

let draw_span ?font ({ text; width; style } : Frame.Span.t) =
  let attrs = Theme.attrs ?font style in
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
         View.hcat (List.map spans ~f:(draw_span ?font))))
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

module File_picker_host = struct
  type t =
    { initial_ui : Ui_state.t
    ; runtime : Ches_file_picker_host.Runtime.t
    ; consume : Ches_tile.View_id.t Ches_file_picker.Model.Request.t -> unit
    }
end

module Content_picker_host = struct
  type t =
    { initial_ui : Ui_state.t
    ; runtime : Ches_content_picker_host.Runtime.t
    ; consume : Ches_tile.View_id.t Ches_content_picker.Model.intent -> unit
    }
end

let app ?(smear_enabled = false) ?buffer_presentation ?report ?source ?font ?file_picker ?content_picker controller ~exit ~dimensions (local_ graph)
  =
  (* Scope belongs to this editor instance, not the currently active tab. Directory
     startup and unnamed documents use the session's explicit startup directory. *)
  let production_runtime = Ches_file_picker_host.Runtime.create () in
  let content_runtime = Option.value_map content_picker
    ~default:(Ches_content_picker_host.Runtime.create ())
    ~f:(fun host -> host.Content_picker_host.runtime) in
  let starting_directory = match Ches_core.Editor.path (Ches_app.Controller.editor controller) with
    | None -> Core_unix.getcwd ()
    | Some path -> if Ches_app.Controller.Kind.equal (Ches_app.Controller.kind controller) Directory
      then path else Filename.dirname path in
  let project_root = Ches_file_discovery.Project_root.find
    (Filename.concat starting_directory "__picker_scope__") in
  let file_runtime = Option.value_map file_picker ~default:production_runtime
    ~f:(fun host -> host.File_picker_host.runtime) in
  let initial_ui = match content_picker, file_picker with
    | Some _, Some _ -> invalid_arg "Only one initial picker host is allowed"
    | Some host, None -> host.Content_picker_host.initial_ui
    | None, Some host -> host.File_picker_host.initial_ui
    | None, None -> Ui_state.create ~smear_enabled ?buffer_presentation ?report
        ~source_attached:(Option.is_some source) controller in
  let current_ui = ref initial_ui in
  let preview = Ches_file_preview.Provider.create ~buffer:(fun ~path ->
    Ches_file_preview.Buffer_snapshot.lookup (Ui_state.session !current_ui) ~path) () in
  let preview_pumping = ref false in
  let preview_revision = ref None in
  let clear_preview () =
    preview_revision := None;
    Ches_file_preview.Provider.clear preview;
    Option.iter (Ui_state.file_picker !current_ui) ~f:File_picker_tile.clear_preview in
  let synchronize_preview model =
    (* Replacements must release the old screen payload as well as provider work. *)
    let old_picker = Ui_state.file_picker !current_ui in
    let picker = if Ui_state.exited model then None else Ui_state.file_picker model in
    if not (Option.equal phys_equal old_picker picker) then (
      clear_preview ());
    current_ui := model;
    let selected_model = Option.map picker ~f:(fun picker ->
      Ches_file_picker.Interaction.model (File_picker_tile.session picker)) in
    let expected = Ches_file_preview.Provider.follow preview selected_model in
    let revision = Option.bind expected ~f:(fun request ->
      Option.bind (Ches_app.Session.find_resource (Ui_state.session model)
        (Ches_file_picker.Model.Candidate.Id.to_string request.selected))
        ~f:(fun (id, controller) -> match Ches_app.Controller.kind controller with
          | Directory -> None
          | File -> Some (id, Ches_core.Editor.revision (Ches_app.Controller.editor controller)))) in
    let refresh = match !preview_revision, expected with
      | Some (previous, old_revision), Some expected ->
        Ches_file_preview.Model.equal_request previous expected
        && not (Option.equal
          (fun (id, revision) (other_id, other_revision) ->
            Ches_app.Buffer_id.equal id other_id && revision = other_revision)
          old_revision revision)
      | _ -> false in
    let expected = if refresh then Ches_file_preview.Provider.follow ~refresh:true preview selected_model
      else expected in
    preview_revision := Option.map expected ~f:(fun expected -> expected, revision);
    Option.iter picker ~f:(fun picker ->
      File_picker_tile.expect_preview picker expected;
      Option.iter (Ches_file_preview.Provider.snapshot preview) ~f:(fun snapshot ->
        ignore (File_picker_tile.install_preview picker snapshot : bool)));
    model in
  let picker_turn_scheduled = ref false in
  let active_file_session = ref (Option.bind file_picker ~f:(fun host ->
    Option.map (Ui_state.file_picker host.File_picker_host.initial_ui)
      ~f:File_picker_tile.session)) in
  let active_line_session = ref None in
  let active_content_session = ref (Option.bind content_picker ~f:(fun host ->
    Option.map (Ui_state.content_picker host.Content_picker_host.initial_ui)
      ~f:Content_picker_tile.session)) in
  let line_needs_turn model =
    not (Ui_state.exited model)
    && Option.exists (Ui_state.line_picker model) ~f:(fun picker ->
      Ches_line_picker.Lines.busy (Line_picker_tile.session picker))
  in
  let picker_needs_turn model =
    not (Ui_state.exited model)
    && Option.exists (Ui_state.file_picker model) ~f:(fun picker ->
      let session = File_picker_tile.session picker in
      Ches_file_picker.Interaction.busy session
      || match (Ches_file_picker.Model.discovery (Ches_file_picker.Interaction.model session)).status with
         | Loading | Partial -> true
         | Complete _ | Failed _ | Cancelled -> false)
  in
  let model, inject =
    Bonsai.state_machine_with_input
       ~default_model:initial_ui
      ~apply_action:(fun context input model inputs ->
        match input with
         | Inactive -> clear_preview (); model
        | Active ({ Dimensions.width; height }, write_to_tty) ->
           let was_running = not (Ui_state.exited model) in
           if List.exists inputs ~f:(function Ui_state.Input.Resize -> true | _ -> false)
           then clear_preview ();
          let activate_pickers model =
            let model, activate_files = Ui_state.take_file_picker_activation model in
            let model = if not activate_files then model else
              match Ches_file_picker_host.Runtime.open_picker file_runtime model
                ~root:project_root ~width ~height with
              | Ok model -> model
              | Error error -> Ui_state.with_notice model (Error.to_string_hum error) in
            let model, activate_contents = Ui_state.take_content_picker_activation model in
            let model = if not activate_contents then model else
              match Ches_content_picker_host.Runtime.open_picker content_runtime model
                ~root:project_root ~width ~height with
              | Ok model -> model
              | Error error -> Ui_state.with_notice ~source:"content picker" model (Error.to_string_hum error) in
             synchronize_preview model
          in
           let model, status = Ui_state.apply_all ~after_step:activate_pickers model ~width ~height inputs in
           let model = synchronize_preview model in
           if not !preview_pumping && Option.is_some (Ches_file_preview.Provider.snapshot preview)
           then (
             preview_pumping := true;
             let rec pump () =
               (* Capture BEFORE snapshot/injection: injection yields and may itself
                  change selection. Notifications retain no queued payloads. *)
               let changed = Ches_file_preview.Provider.changed preview in
               match Ches_file_preview.Provider.snapshot preview with
               | None -> preview_pumping := false; Effect.Ignore
               | Some snapshot ->
                 let%bind.Effect () = Bonsai.Apply_action_context.inject context
                   [ Ui_state.Input.File_preview snapshot ] in
                 let%bind.Effect () = Effect.of_deferred_thunk (fun () -> changed) in
                 pump () in
             Bonsai.Apply_action_context.schedule_event context (pump ()));
          active_file_session := Option.map (Ui_state.file_picker model) ~f:File_picker_tile.session;
          active_line_session := Option.map (Ui_state.line_picker model) ~f:Line_picker_tile.session;
          active_content_session := Option.map (Ui_state.content_picker model) ~f:Content_picker_tile.session;
          let model, clipboard = Ui_state.take_clipboard model in
          Option.iter clipboard ~f:(fun text ->
            Bonsai.Apply_action_context.schedule_event
              context
              (write_to_tty (Osc52.set_clipboard text)));
          (* Requests leave as data: the source is told after this transition, which
             never waits for it. *)
          let model, requests = Ui_state.take_source_requests model in
          Option.iter source ~f:(fun source ->
            List.iter requests ~f:(fun request ->
              Bonsai.Apply_action_context.schedule_event
                context
                (Effect.of_thunk (fun () -> Ches_source.Source.send source request))));
          let model, requests = Ui_state.take_file_requests model in
          List.iter requests ~f:(fun request ->
            Bonsai.Apply_action_context.schedule_event context
              (match file_picker with
               | Some host -> Effect.of_thunk (fun () -> host.consume request)
               | None -> Bonsai.Apply_action_context.inject context
                   [ Ui_state.Input.File_picker_accept request ]));
          let model, requests = Ui_state.take_content_requests model in
          List.iter requests ~f:(fun request ->
            Bonsai.Apply_action_context.schedule_event context
              (match content_picker with
               | Some host -> Effect.of_thunk (fun () -> host.consume request)
               | None -> Bonsai.Apply_action_context.inject context
                   [ Ui_state.Input.Content_picker_accept request ]));
          if not !picker_turn_scheduled
             && (line_needs_turn model || picker_needs_turn model
                 || Ches_content_picker_host.Runtime.needs_turn content_runtime model)
          then (
            picker_turn_scheduled := true;
            Bonsai.Apply_action_context.schedule_event context
              (let%bind.Effect events = Effect.of_deferred_thunk (fun () ->
                 if line_needs_turn model then (
                   let generation = Ui_state.line_picker_generation model in
                   Async.Deferred.map (Async.Scheduler.yield ()) ~f:(fun () ->
                     [ Ui_state.Input.Line_picker_work generation ]))
                 else if Ches_content_picker_host.Runtime.needs_turn content_runtime model then
                   Ches_content_picker_host.Runtime.next content_runtime model
                 else if picker_needs_turn model then
                   Ches_file_picker_host.Runtime.next file_runtime model
                 else Async.return []) in
               picker_turn_scheduled := false;
               (* Obsolete turns still wake replacements, without doing their work. *)
               Bonsai.Apply_action_context.inject context events));
          (match status with
           | Exit when was_running ->
              Option.iter source ~f:Ches_source.Source.stop;
              Ches_file_picker_host.Runtime.cancel file_runtime;
              Ches_content_picker_host.Runtime.cancel content_runtime;
             Bonsai.Apply_action_context.schedule_event context (exit ())
           | Exit | Running -> ());
          model)
      (let%arr dimensions
       and write_to_tty = Expert.Write_to_tty.write_string_to_tty graph in
       dimensions, write_to_tty)
      graph
  in
  Bonsai.Edge.lifecycle ~on_activate:(let%arr inject in inject [])
    ~on_deactivate:(Bonsai.return
      (Effect.of_thunk (fun () ->
        Option.iter !active_file_session ~f:(fun session ->
          Ches_file_picker.Interaction.cancel session ~release:(fun () -> ()));
         clear_preview ();
         Ches_file_picker_host.Runtime.cancel file_runtime))) graph;
  Bonsai.Edge.lifecycle ~on_activate:(let%arr inject in inject [])
    ~on_deactivate:(Bonsai.return
      (Effect.of_thunk (fun () ->
        Option.iter !active_content_session ~f:(fun session ->
          Ches_content_picker.Model.cancel session ~release:(fun () -> ()));
        Ches_content_picker_host.Runtime.cancel content_runtime))) graph;
  Bonsai.Edge.lifecycle
    ~on_deactivate:(Bonsai.return (Effect.of_thunk (fun () ->
      Option.iter !active_line_session ~f:(fun session ->
        Ches_line_picker.Lines.cancel session ~release:(fun () -> ()))))) graph;
  (* Source events enter like keys, as inputs of their own transition, one bounded batch
     at a time, so keys typed during a burst are handled between batches. *)
   Bonsai.Edge.lifecycle
     ~on_deactivate:(let%arr model in
       Effect.of_thunk (fun () -> Ches_app.Session.dispose (Ui_state.session model)))
     graph;
   Option.iter source ~f:(fun source ->
     Bonsai.Edge.lifecycle
        ~on_deactivate:(Bonsai.return (Effect.of_thunk (fun () -> Ches_source.Source.stop source)))
      ~on_activate:
        (let%arr inject in
         let rec pump () =
           let%bind.Effect events =
             Effect.of_deferred_thunk (fun () -> Ches_source.Source.next_batch source)
           in
           let%bind.Effect () =
             inject (List.map events ~f:(fun event -> Ui_state.Input.Source event))
           in
           pump ()
         in
         pump ())
      graph);
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

let run ?font ?buffer_presentation ?report ?source controller =
  (* Terminating signals shut down through Async, whose shutdown handlers restore the
     terminal; the default action would leave it in raw mode on the alternate screen.
     Unsaved changes are discarded. *)
  Async.Signal.handle
    [ Async.Signal.term; Async.Signal.hup ]
    ~f:(fun (_ : Signal.t) -> Async.shutdown 1);
  Async.Deferred.map
    (Bonsai_term.start_with_exit
       ~dispose:true
       ~mouse:No_mouse_events
       ~bpaste:true
       (app ~smear_enabled:true ?buffer_presentation ?report ?source ?font controller))
    ~f:(fun result ->
      Option.iter source ~f:Ches_source.Source.stop;
      Ches_app.Controller.close controller;
      result)
;;
