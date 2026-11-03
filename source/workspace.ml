open! Core
open! Async

(** For single-document drivers, such as the synthetic checker. One per lexical resource prevents
    URI aliases and revision histories from being silently merged. *)
let start ~create () =
  Source.create (fun ~emit ->
    let drivers = String.Table.create () in
    let stopped = ref false in
    let close resource =
      Option.iter (Hashtbl.find drivers resource) ~f:(fun (_, source, finished) ->
        Ivar.fill_if_empty finished ();
        Source.send source (Document_closed { resource }); Source.stop source);
      Hashtbl.remove drivers resource
    in
    let open_document resource generation =
      close resource;
      Option.iter (create resource) ~f:(fun source ->
        let finished = Ivar.create () in
        Hashtbl.set drivers ~key:resource ~data:(generation, source, finished);
        let rec scoped (event : Ches_error.Source_event.t) : Ches_error.Source_event.t =
          let name source = sprintf "%s#%d" source generation in
           match event with
           | Servers _ -> Servers []
            | Completion reply -> Completion { reply with source = name reply.source }
            | Query_result reply -> Query_result { reply with source = name reply.source }
            | Instance_context_changed info -> Instance_context_changed { info with source = name info.source }
            | Completion_metadata info -> Completion_metadata { info with source = name info.source }
          | Diagnostics d -> Diagnostics { d with source = name d.source }
          | Started d -> Started { d with source = name d.source }
          | Stopped d -> Stopped { d with source = name d.source }
          | Unavailable d -> Unavailable { d with source = name d.source }
          | Owned d -> Owned { d with event = scoped d.event }
        in
        let rec pump () =
          let%bind result = Deferred.choose
            [ Deferred.choice (Ivar.read finished) (fun () -> `Finished)
            ; Deferred.choice (Source.next_batch source) (fun events -> `Events events) ] in
          match result with
          | `Finished -> return ()
          | `Events events ->
            if not !stopped && Option.exists (Hashtbl.find drivers resource) ~f:(fun (current, _, _) -> current = generation)
             then List.iter events ~f:(fun event -> match event with
                | Servers _ -> emit (Ches_error.Source_event.Servers [])
                | Instance_context_changed _ -> emit (scoped event)
               | _ -> emit (Ches_error.Source_event.Owned { resource; generation; event = scoped event }));
            if !stopped || Ivar.is_full finished then Deferred.unit else pump ()
        in
        don't_wait_for (pump ()))
    in
    { Source.Driver.handle = (fun request ->
         match request with
          | Inspect -> emit (Ches_error.Source_event.Servers [])
         | Query q ->
           (match Hashtbl.find drivers q.token.resource with
            | Some (_, source, _) -> Source.send source request
            | None -> emit (Ches_error.Source_event.Query_result { token = q.token;
                cursor = q.cursor; kind = q.kind; source = "source";
                result = Ches_error.Language_query.unavailable q.kind "No language server attached to this document" }))
         | Cancel_query token ->
           Option.iter (Hashtbl.find drivers token.resource) ~f:(fun (_, source, _) -> Source.send source request)
        | Ches_error.Source_request.Document_opened { resource; generation } -> open_document resource generation
        | Document_closed { resource } -> close resource
        | Document_changed { resource; _ } | Document_saved { resource; _ } ->
          Option.iter (Hashtbl.find drivers resource) ~f:(fun (_, source, _) -> Source.send source request)
         | Complete { token = { resource; _ }; _ } | Cancel_completion { resource; _ } ->
           Option.iter (Hashtbl.find drivers resource) ~f:(fun (_, source, _) -> Source.send source request)
         | Resolve_completion { token = { resource; _ }; _ } ->
           Option.iter (Hashtbl.find drivers resource) ~f:(fun (_, source, _) -> Source.send source request)
        | Restart | Kill -> Hashtbl.iter drivers ~f:(fun (_, source, _) -> Source.send source request))
    ; stop = (fun () -> stopped := true; List.iter (Hashtbl.keys drivers) ~f:close)
    })
;;
