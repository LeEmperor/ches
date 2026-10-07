open! Core
open! Async

(** Existing drivers are single-document. One driver per lexical resource prevents
    URI aliases and revision histories from being silently merged. *)
let start ~create () =
  Source.create (fun ~emit ->
    let drivers = String.Table.create () in
    let stopped = ref false in
    let close resource =
      Option.iter (Hashtbl.find drivers resource) ~f:(fun (_, source) ->
        Source.send source (Document_closed { resource }); Source.stop source);
      Hashtbl.remove drivers resource
    in
    let open_document resource generation =
      close resource;
      Option.iter (create resource) ~f:(fun source ->
        Hashtbl.set drivers ~key:resource ~data:(generation, source);
        let rec scoped (event : Ches_error.Source_event.t) : Ches_error.Source_event.t =
          let name source = sprintf "%s#%d" source generation in
          match event with
          | Diagnostics d -> Diagnostics { d with source = name d.source }
          | Started d -> Started { d with source = name d.source }
          | Stopped d -> Stopped { d with source = name d.source }
          | Unavailable d -> Unavailable { d with source = name d.source }
          | Owned d -> Owned { d with event = scoped d.event }
        in
        let rec pump () =
          let%bind events = Source.next_batch source in
          if not !stopped && Option.exists (Hashtbl.find drivers resource) ~f:(fun (current, _) -> current = generation)
          then List.iter events ~f:(fun event -> emit (Ches_error.Source_event.Owned { resource; generation; event = scoped event }));
          if !stopped then Deferred.unit else pump ()
        in
        don't_wait_for (pump ()))
    in
    { Source.Driver.handle = (fun request ->
        match request with
        | Ches_error.Source_request.Document_opened { resource; generation } -> open_document resource generation
        | Document_closed { resource } -> close resource
        | Document_changed { resource; _ } | Document_saved { resource; _ } ->
          Option.iter (Hashtbl.find drivers resource) ~f:(fun (_, source) -> Source.send source request)
        | Restart | Kill -> Hashtbl.iter drivers ~f:(fun (_, source) -> Source.send source request))
    ; stop = (fun () -> stopped := true; List.iter (Hashtbl.keys drivers) ~f:close)
    })
;;
