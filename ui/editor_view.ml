open! Core
open Bonsai_term
open Bonsai.Let_syntax
open Ches_screen

let draw_span ?theme ?font ({ text; width; style } : Frame.Span.t) =
  let attrs = Theme.attrs ?theme ?font style in
  let view = View.text ~attrs text in
  let drawn = View.width view in
  if drawn = width
  then view
  else if drawn > width
  then View.crop ~r:(drawn - width) view
  else View.hcat [ view; View.rectangle ~attrs ~width:(width - drawn) ~height:1 () ]
;;

let draw_smear ?theme ?font (frame : Frame.t) =
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
          :: View.text ~attrs:(Theme.attrs ?theme ?font Smear) "█"
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

let draw_base ?theme ?font (frame : Frame.t) =
  View.vcat
    (List.map frame.rows ~f:(fun spans ->
       View.hcat (List.map spans ~f:(draw_span ?theme ?font))))
;;

let draw_overlay ?theme ?font ~base frame =
  View.zcat [ draw_smear ?theme ?font frame; base ]
;;

let draw ?theme ?font frame =
  draw_overlay ?theme ?font ~base:(draw_base ?theme ?font frame) frame
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

let apply_startup_configuration ?theme_override ui result =
  let apply settings = Ui_state.apply_configuration ?theme_override ui settings in
  match Result.bind result ~f:apply with
  | Ok ui -> ui
  | Error error ->
    let ui = match apply Ches_config_runtime.Settings.default with
      | Ok ui -> ui
      | Error _ -> ui in
    Ui_state.with_notice ~source:"configuration" ui
      ("Configuration startup failed; using defaults: " ^ error)
;;

let app_with_terminal ~terminal ?snippets ?configuration ?startup_configuration ?configuration_path ?(smear_enabled = false) ?(zen = false) ?bare ?theme ?buffer_presentation ?report ?source ?vcs ?font ?file_picker ?content_picker controller ~exit ~dimensions (local_ graph)
  =
  (* Scope belongs to this editor instance, not the currently active tab. Directory
     startup and unnamed documents use the session's explicit startup directory. *)
  let production_runtime = Ches_file_picker_host.Runtime.create () in
  let harness = Harness_host.create () in
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
  (* The VCS view looks for a repository from the startup directory. Without a
     runner it is known only by id, so Space g reports why nothing opens. *)
  let vcs_entry = match vcs with
    | Some _ ->
      let cwd = if Filename.is_relative starting_directory
        then Filename.concat (Core_unix.getcwd ()) starting_directory
        else starting_directory in
      Vcs_view.entry ~cwd ()
    | None ->
      View_registry.Entry.unavailable Vcs_view.id ~title:"VCS"
        ~notice:"VCS unavailable in this session" in
  let initial_ui = match content_picker, file_picker with
    | Some _, Some _ -> invalid_arg "Only one initial picker host is allowed"
    | Some host, None -> host.Content_picker_host.initial_ui
    | None, Some host -> host.File_picker_host.initial_ui
    | None, None ->
      let ui = Ui_state.create ~smear_enabled ?bare ?theme ?buffer_presentation ?report
        ~source_attached:(Option.is_some source) ~views:[ vcs_entry ] controller in
      (* Headless assembly retains Workspace. Enter Zen through the normal command
         path only for frontend startup; Bare keeps its Workspace return target.
         The first render reconciles the actual terminal dimensions. *)
      if zen && not (Ui_state.bare ui) then
        fst (Ui_state.apply_all ui ~width:0 ~height:0
          (List.map (String.to_list " vz") ~f:(fun c ->
             Ui_state.Input.Key (Ches_input.Key.char c))))
      else ui in
  let configuration_path = Option.value_or_thunk configuration_path ~default:(fun () ->
    match Ches_config_runtime.Loader.config_path ~getenv:Sys.getenv with
    | Some path -> Ok path
    | None -> Error "Cannot locate configuration: set an absolute XDG_CONFIG_HOME or a non-empty HOME") in
  let initial_ui = Ui_state.with_configuration_path initial_ui configuration_path in
  let initial_ui = Option.value_map startup_configuration ~default:initial_ui
    ~f:(apply_startup_configuration ?theme_override:theme initial_ui) in
  let current_ui = ref initial_ui in
  let navigation_preview = Navigation_preview_host.create ~buffer:(fun request ->
    Ui_state.navigation_preview_buffer !current_ui request) () in
  let navigation_preview_pumping = ref false in
  let synchronize_navigation_preview model =
    current_ui := model;
    Navigation_preview_host.follow navigation_preview
      (if Ui_state.exited model then None else Ui_state.navigation_preview_request model);
    model in
  let configuration = Option.value_or_thunk configuration ~default:(fun () -> Configuration_host.create ()) in
  let snippets = Option.value_or_thunk snippets ~default:Snippet_host.create in
  let word_index = Word_index_host.create () in
  let render_cache = Frame.Cache.create () in
  let last_drawn_theme = ref None in
  let synchronized_dimensions = ref None in
  let preview = Ches_file_preview.Provider.create ~buffer:(fun ~path ->
    Ches_file_preview.Buffer_snapshot.lookup (Ui_state.session !current_ui) ~path) () in
  let preview_pumping = ref false in
  let preview_revision = ref None in
  let clear_preview () =
    Frame.Cache.invalidate render_cache;
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
       || match Ches_file_picker.Model.discovery_status (Ches_file_picker.Interaction.model session) with
         | Loading | Partial -> true
         | Complete _ | Failed _ | Cancelled -> false)
  in
  let model, inject_action =
    Bonsai.state_machine_with_input
       ~default_model:initial_ui
      ~apply_action:(fun context input model action ->
        match input with
         | Inactive -> clear_preview (); Navigation_preview_host.clear navigation_preview; model
         | Active ({ Dimensions.width; height }, write_to_tty) ->
            let model = match action with
              | `Words (request, words) ->
                Frame.Cache.invalidate render_cache;
                Ui_state.receive_word_index model request words
              | `Snippets (generation, result) ->
                Frame.Cache.invalidate render_cache;
                Ui_state.receive_snippets model ~generation result
               | `Configuration (generation, result) ->
                 Frame.Cache.invalidate render_cache;
                 Ui_state.receive_configuration model ~generation result
               | `Navigation_preview snapshot ->
                 Frame.Cache.invalidate render_cache;
                  Ui_state.receive_navigation_preview model snapshot
               | `Harness (request, result) ->
                 Frame.Cache.invalidate render_cache;
                 Ui_state.receive_harness model ~width ~height ~request result
              | `Inputs _ | `Event _ -> model in
            (* Capture belongs to the model at this transition, not the last
               displayed handler: several events can arrive before a redraw. *)
            let inputs = match action with
                | `Words _ | `Snippets _ | `Configuration _ | `Navigation_preview _ | `Harness _ -> []
              | `Inputs inputs -> inputs
              | `Event (event, at) ->
                Terminal_input.inputs ~terminal:(Ui_state.terminal_capturing model) event
                |> List.map ~f:(function
                  | Ui_state.Input.Key key -> Ui_state.Input.Key_at { key; at }
                  | Ui_state.Input.Terminal_key key -> Ui_state.Input.Terminal_key_at { key; at }
                  | input -> input) in
            (* Pure animation turns retain the base image and skip host effects.
               Timeout ticks can flush input, so always use the full path below. *)
            if not (List.is_empty inputs)
               && List.for_all inputs ~f:(function Ui_state.Input.Animation_tick _ -> true | _ -> false)
               && Option.equal [%equal: int * int] !synchronized_dimensions (Some (width, height))
            then (
              let model, _ = Ui_state.apply_all model ~width ~height inputs in
               let model = synchronize_navigation_preview model in
              model)
            else (
            let inputs = if Option.equal [%equal: int * int]
                !synchronized_dimensions (Some (width, height)) then inputs
              else Ui_state.Input.Resize :: inputs in
            synchronized_dimensions := Some (width, height);
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
              synchronize_navigation_preview (synchronize_preview model)
          in
            let model, status = Frame.Cache.apply_inputs render_cache ~after_step:activate_pickers model ~width ~height inputs in
            let model = synchronize_navigation_preview (synchronize_preview model) in
            if not !navigation_preview_pumping
               && Option.is_some (Navigation_preview_host.snapshot navigation_preview)
            then (
              navigation_preview_pumping := true;
              let rec pump () =
                let changed = Navigation_preview_host.changed navigation_preview in
                match Navigation_preview_host.snapshot navigation_preview with
                | None -> navigation_preview_pumping := false; Effect.Ignore
                | Some snapshot ->
                  let%bind.Effect () = Bonsai.Apply_action_context.inject context
                    (`Navigation_preview snapshot) in
                  let%bind.Effect () = Effect.of_deferred_thunk (fun () -> changed) in
                  pump () in
              Bonsai.Apply_action_context.schedule_event context (pump ()));
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
                    (`Inputs [ Ui_state.Input.File_preview snapshot ]) in
                 let%bind.Effect () = Effect.of_deferred_thunk (fun () -> changed) in
                 pump () in
             Bonsai.Apply_action_context.schedule_event context (pump ()));
          active_file_session := Option.map (Ui_state.file_picker model) ~f:File_picker_tile.session;
          active_line_session := Option.map (Ui_state.line_picker model) ~f:Line_picker_tile.session;
          active_content_session := Option.map (Ui_state.content_picker model) ~f:Content_picker_tile.session;
           let model, clipboard = Ui_state.take_clipboard model in
           let model, harness_requests = Ui_state.take_harness_requests model in
           List.iter harness_requests ~f:(fun work ->
             Bonsai.Apply_action_context.schedule_event context
               (let%bind.Effect result = Effect.of_deferred_thunk (fun () -> Harness_host.execute harness work) in
                Bonsai.Apply_action_context.inject context (`Harness (work.action, result))));
          let model, snippet_requests = Ui_state.take_snippet_reload_requests model in
          let model, word_request = Ui_state.take_word_index_request model in
          Bonsai.Apply_action_context.schedule_event context
            (Effect.of_thunk (fun () -> Word_index_host.follow word_index word_request));
          if not (List.is_empty snippet_requests) then
            Bonsai.Apply_action_context.schedule_event context
              (Effect.of_thunk (fun () -> Snippet_host.submit snippets snippet_requests));
          let model, configuration_requests = Ui_state.take_config_reload_requests model in
          if not (List.is_empty configuration_requests) then
            Bonsai.Apply_action_context.schedule_event context
              (Effect.of_thunk (fun () -> Configuration_host.submit configuration configuration_requests));
          let model, terminal_requests = Ui_state.take_terminal_session_requests model in
          if not (List.is_empty terminal_requests) then
            Bonsai.Apply_action_context.schedule_event context
              (Effect.of_thunk (fun () -> Terminal_host.submit_sessions terminal terminal_requests));
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
          (* Views' jobs leave as data too: the runner gets them after this transition.
             Without a runner, each is answered as never started, so no view waits. *)
          let model, jobs = Ui_state.take_vcs_jobs model in
          if not (List.is_empty jobs) then
            Bonsai.Apply_action_context.schedule_event context
              (match vcs with
               | Some host -> Effect.of_thunk (fun () -> Vcs_host.submit host jobs)
               | None -> Bonsai.Apply_action_context.inject context
                   (`Inputs (List.map jobs ~f:(fun job ->
                      Ui_state.Input.Vcs (Finished (Ches_vcs.Job.never_started job))))));
          let model, requests = Ui_state.take_file_requests model in
          List.iter requests ~f:(fun request ->
            Bonsai.Apply_action_context.schedule_event context
              (match file_picker with
               | Some host -> Effect.of_thunk (fun () -> host.consume request)
               | None -> Bonsai.Apply_action_context.inject context
                   (`Inputs [ Ui_state.Input.File_picker_accept request ])));
          let model, requests = Ui_state.take_content_requests model in
          List.iter requests ~f:(fun request ->
            Bonsai.Apply_action_context.schedule_event context
              (match content_picker with
               | Some host -> Effect.of_thunk (fun () -> host.consume request)
               | None -> Bonsai.Apply_action_context.inject context
                   (`Inputs [ Ui_state.Input.Content_picker_accept request ])));
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
               Bonsai.Apply_action_context.inject context (`Inputs events)));
          (match status with
             | Exit when was_running ->
               Harness_host.stop harness;
               Navigation_preview_host.stop navigation_preview;
              Word_index_host.stop word_index;
              Snippet_host.stop snippets;
              Configuration_host.stop configuration;
              Terminal_host.stop terminal;
              Async.don't_wait_for (Terminal_host.shutdown terminal);
              Option.iter source ~f:Ches_source.Source.stop;
              (* Children get SIGTERM now; [run] waits for them after the terminal
                 closes ([Vcs_host.shutdown]), never here. *)
              Option.iter vcs ~f:Vcs_host.stop;
              Ches_file_picker_host.Runtime.cancel file_runtime;
              Ches_content_picker_host.Runtime.cancel content_runtime;
             Bonsai.Apply_action_context.schedule_event context (exit ())
           | Exit | Running -> ());
           model))
      (let%arr dimensions
       and write_to_tty = Expert.Write_to_tty.write_string_to_tty graph in
       dimensions, write_to_tty)
      graph
  in
  let inject = let%arr inject_action in fun inputs -> inject_action (`Inputs inputs) in
  Bonsai.Edge.lifecycle
    ~on_deactivate:(Bonsai.return (Effect.of_thunk (fun () -> Harness_host.stop harness))) graph;
  Bonsai.Edge.lifecycle
    ~on_deactivate:(Bonsai.return (Effect.of_thunk (fun () -> Word_index_host.stop word_index)))
    ~on_activate:(let%arr inject_action in
      let rec pump () =
        let%bind.Effect reply = Effect.of_deferred_thunk (fun () -> Word_index_host.next word_index) in
        match reply with
        | None -> Effect.Ignore
        | Some reply -> let%bind.Effect () = inject_action (`Words reply) in pump ()
      in pump ())
    graph;
  Bonsai.Edge.lifecycle
    ~on_deactivate:(Bonsai.return (Effect.of_thunk (fun () -> Snippet_host.stop snippets)))
    ~on_activate:(let%arr inject_action in
      let rec pump () =
        let%bind.Effect reply = Effect.of_deferred_thunk (fun () -> Snippet_host.next snippets) in
        match reply with
        | None -> Effect.Ignore
        | Some reply ->
          let%bind.Effect () = inject_action (`Snippets reply) in
          pump ()
      in
      pump ())
    graph;
  Bonsai.Edge.lifecycle
    ~on_deactivate:(Bonsai.return (Effect.of_thunk (fun () -> Configuration_host.stop configuration)))
    ~on_activate:(let%arr inject_action in
      let rec pump () =
        let%bind.Effect reply = Effect.of_deferred_thunk (fun () -> Configuration_host.next configuration) in
        match reply with
        | None -> Effect.Ignore
        | Some reply ->
          let%bind.Effect () = inject_action (`Configuration reply) in
          pump ()
      in
      pump ())
    graph;
   Bonsai.Edge.lifecycle
     ~on_deactivate:(Bonsai.return (Effect.of_thunk (fun () -> Navigation_preview_host.stop navigation_preview)))
     graph;
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
  (* The runner's events enter the same way, one batch per transition. The next batch
     is asked for only once the previous one is injected; after [stop] none comes, so
     this loop never holds exit open. *)
  Option.iter vcs ~f:(fun host ->
    Bonsai.Edge.lifecycle
      ~on_deactivate:(Bonsai.return (Effect.of_thunk (fun () -> Vcs_host.stop host)))
      ~on_activate:
        (let%arr inject in
         let rec pump () =
           let%bind.Effect inputs =
             Effect.of_deferred_thunk (fun () -> Vcs_host.next_inputs host)
           in
           let%bind.Effect () = inject inputs in
           pump ()
         in
         pump ())
      graph);
  Bonsai.Edge.lifecycle
    ~on_deactivate:(Bonsai.return (Effect.of_thunk (fun () ->
      Async.don't_wait_for (Terminal_host.shutdown terminal))))
    ~on_activate:(let%arr inject in
      let rec pump () =
        let%bind.Effect event = Effect.of_deferred_thunk (fun () ->
          Terminal_host.next_session_update terminal) in
        match event with
        | None -> Effect.Ignore
        | Some (terminal, generation, event) ->
          let%bind.Effect () = inject [ Ui_state.Input.Terminal_session_update { terminal; generation; event } ] in
          pump ()
      in
      pump ())
    graph;
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
       (let%arr inject and get_current_time in
        let%bind.Effect now = get_current_time in
        (* Read the transition's latest state, including keys delivered since the
           last display. All deadlines use the same clock, independently of smear. *)
        let model = !current_ui in
        let inputs =
          (if Ui_state.toggle_key_pending model then [ Ui_state.Input.Toggle_tick now ] else [])
          @ (if Ui_state.terminal_key_pending model then [ Ui_state.Input.Terminal_tick now ] else [])
          @ (if Animation.active (Ui_state.animation model)
             then [ Ui_state.Input.Animation_tick now ] else []) in
        if List.is_empty inputs then Effect.Ignore else inject inputs)
      graph
  in
  let rendered =
    let%arr model
    and { Dimensions.width; height } = dimensions in
    let theme = Ui_state.theme model in
    if not (Option.equal Ches_theme.Theme.equal !last_drawn_theme (Some theme))
    then (
      Frame.Cache.invalidate render_cache;
      last_drawn_theme := Some theme);
    Frame.Cache.get render_cache model ~width ~height ~draw_base:(draw_base ~theme ?font)
  in
  let frame = let%arr frame, _ = rendered in frame in
  let set_cursor = Effect.set_cursor graph in
  Bonsai.Edge.after_display
    (let%arr frame and set_cursor in
     set_cursor (cursor frame))
    graph;
  let view =
    let%arr frame, base = rendered
    and model in
    draw_overlay ~theme:(Ui_state.theme model) ?font ~base frame
  in
  let handler =
    let%arr inject_action and get_current_time in
    fun event ->
      (* Date the event before it queues; normalization uses that same timestamp
         for every resulting key and the same clock as timeout ticks. *)
      let%bind.Effect at = get_current_time in
      inject_action (`Event (event, at))
  in
  ~view, ~handler
;;

let app ?terminal ?snippets ?configuration ?startup_configuration ?configuration_path ?smear_enabled ?(zen = false) ?bare ?theme ?buffer_presentation ?report ?source ?vcs ?font
  ?file_picker ?content_picker controller ~exit ~dimensions (local_ graph) =
  let terminal = Option.value_or_thunk terminal ~default:Terminal_host.create in
  app_with_terminal ~terminal ?snippets ?configuration ?startup_configuration ?configuration_path ?smear_enabled ~zen ?bare ?theme ?buffer_presentation
    ?report ?source ?vcs ?font ?file_picker ?content_picker controller ~exit ~dimensions graph
;;

let run ?configuration ?startup_configuration ?configuration_path ?(smear_enabled = false) ?(zen = false) ?bare ?theme ?font ?buffer_presentation ?report ?source ?vcs controller =
  let configuration = Option.value_or_thunk configuration ~default:(fun () -> Configuration_host.create ()) in
  let configuration_at_shutdown = ref (Some configuration) in
  Async.Shutdown.at_shutdown (fun () ->
    match !configuration_at_shutdown with
    | None -> Async.return ()
    | Some host ->
      let%map.Async.Deferred () = Configuration_host.shutdown host in
      configuration_at_shutdown := None);
  (* Also cover startup helpers: Async shutdown lets the loader reap children.
     Once mounted, terminal shutdown restores raw mode and the alternate screen. *)
  Async.Signal.handle
    [ Async.Signal.term; Async.Signal.hup; Async.Signal.int; Async.Signal.quit ]
    ~f:(fun (_ : Signal.t) -> Async.shutdown 1);
  let%bind.Async.Deferred startup_configuration = match startup_configuration with
    | Some result -> Async.return result
    | None -> Configuration_host.startup configuration in
  let terminal = Terminal_host.create () in
  (* Shutdown hooks outlive [run]; release their runtime reference after cleanup. *)
  let terminal_at_shutdown = ref (Some terminal) in
  Async.Shutdown.at_shutdown (fun () ->
    match !terminal_at_shutdown with
    | None -> Async.return ()
    | Some terminal ->
      let%map.Async.Deferred () = Terminal_host.shutdown terminal in
      terminal_at_shutdown := None);
  (* However the process ends, git children get their termination grace, so none is
     left holding [index.lock]. Idempotent with the wait below. *)
  Option.iter vcs ~f:(fun host ->
    Async.Shutdown.at_shutdown (fun () ->
      Async.Deferred.ignore_m (Vcs_host.shutdown host)));
  Async.Deferred.bind
    (Bonsai_term.start_with_exit
       ~dispose:true
       ~mouse:No_mouse_events
       ~bpaste:true
        (app_with_terminal ~terminal ~configuration ~startup_configuration ?configuration_path ~smear_enabled ~zen ?bare ?theme ?buffer_presentation ?report ?source ?vcs ?font controller))
    ~f:(fun result ->
      Configuration_host.stop configuration;
      Option.iter source ~f:Ches_source.Source.stop;
      Ches_app.Controller.close controller;
      let%bind.Async.Deferred () = Terminal_host.shutdown terminal in
      terminal_at_shutdown := None;
      let%bind.Async.Deferred () = Configuration_host.shutdown configuration in
      configuration_at_shutdown := None;
      let%map.Async.Deferred (_ : [ `Finished | `Timed_out ]) =
        match vcs with
        | None -> Async.return `Finished
        | Some host -> Vcs_host.shutdown host
      in
      result)
;;
