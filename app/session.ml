open! Core
open Ches_core
open Ches_input
module Feedback = Ches_error.Error

type buffer = { id : Buffer_id.t; controller : Controller.t; generation : int }
type placement = Major | Side
type directory_presentation =
  { buffer : Buffer_id.t; placement : placement; target_group : Group_id.t; return_target : Buffer_id.t option }
type t =
  { cwd : string
  ; startup_directory : string
  ; cell_width : Cell_layout.Width.t
  ; keymap_config : Keymap.Config.t
  ; buffers : buffer list
  ; resources : Buffer_id.t String.Map.t
  ; active : Buffer_id.t option
  ; next_id : int
  ; next_generation : int
  ; feedback : Feedback.t
  ; register : Register.t option
  ; clipboard : string option
  ; saved : Controller.Saved.t list
  ; closed : string list
  ; exited : bool
  ; empty_keymap : Keymap.t
  ; directories : Directory_buffer.t list
  ; directory : Buffer_id.t option
  ; remembered : Buffer_id.t option
  ; return_file : Buffer_id.t option
  ; placement : placement
  ; directory_focused : bool
  }

let buffers t = List.map t.buffers ~f:(fun b -> b.id, b.controller)
let active_id t = t.active
let group_id _ = Group_id.of_int 1
let startup_directory t = t.startup_directory
let exited t = t.exited
let normalize t = Resource.normalize ~cwd:t.cwd
let find t id = List.find t.buffers ~f:(fun b -> Buffer_id.equal b.id id) |> Option.map ~f:(fun b -> b.controller)
let source_generation t id = List.find t.buffers ~f:(fun b -> Buffer_id.equal b.id id) |> Option.map ~f:(fun b -> b.generation)
let directory_buffer t = Option.bind t.directory ~f:(fun id -> List.find t.directories ~f:(fun d -> Buffer_id.equal d.id id))
let input_directory t = if t.directory_focused then directory_buffer t else None
let context_id t = if t.directory_focused then t.directory else t.active
let directory_presentation t = Option.map t.directory ~f:(fun buffer ->
  { buffer; placement = t.placement; target_group = group_id t; return_target = t.return_file })
let has_buffer t id = Option.is_some (find t id) || List.exists t.directories ~f:(fun d -> Buffer_id.equal d.id id)
let active_controller t = Option.map (match input_directory t with Some d -> Some d.controller | None -> Option.bind t.active ~f:(find t)) ~f:(fun c ->
  Controller.with_register (Controller.with_feedback c t.feedback) t.register)
let find_resource t resource =
  let resource = normalize t resource in
  Option.bind (Map.find t.resources resource) ~f:(fun id -> Option.map (find t id) ~f:(fun c -> id, c))
;;
type resource_buffer = File_buffer of Buffer_id.t * Controller.t | Directory_buffer of Directory_buffer.t
let find_resource_buffer t resource =
  match find_resource t resource with
  | Some (id, controller) -> Some (File_buffer (id, controller))
  | None -> Option.map (List.find t.directories ~f:(fun d -> String.equal d.path (normalize t resource))) ~f:(fun d -> Directory_buffer d)
;;

let create ?(cwd = Core_unix.getcwd ()) ?keymap_config ~cell_width controller =
  let keymap_config = Option.value keymap_config ~default:(Keymap.config (Controller.keymap controller)) in
  let path = Editor.path (Controller.editor controller) in
  let controller = Option.value_map path ~default:controller ~f:(fun p -> Controller.with_path controller (Resource.normalize ~cwd p)) in
  let directory_start = Controller.Kind.equal (Controller.kind controller) Directory in
  let startup_directory = Option.value_map path ~default:cwd ~f:(fun p -> if directory_start then Resource.normalize ~cwd p else Filename.dirname (Resource.normalize ~cwd p)) in
  let directories = if directory_start then [ Directory_buffer.load ~id:(Buffer_id.of_int 1) ~path:startup_directory ~cell_width ~keymap_config () |> Or_error.ok_exn ] else [] in
  if directory_start then Controller.close controller;
  { cwd; startup_directory
   ; cell_width; keymap_config; buffers = (if directory_start then [] else [ { id = Buffer_id.of_int 1; controller; generation = 1 } ])
  ; resources = (if directory_start then String.Map.empty else Option.value_map path ~default:String.Map.empty ~f:(fun p -> String.Map.singleton (Resource.normalize ~cwd p) (Buffer_id.of_int 1)))
   ; active = (if directory_start then None else Some (Buffer_id.of_int 1)); next_id = 2; next_generation = 2; feedback = Controller.feedback controller
  ; register = Editor.unnamed_register (Controller.editor controller); clipboard = None
  ; saved = []; closed = []; exited = false; empty_keymap = Keymap.create keymap_config
  ; directories; directory = (if directory_start then Some (Buffer_id.of_int 1) else None)
   ; remembered = (if directory_start then Some (Buffer_id.of_int 1) else None); return_file = None
   ; placement = Major; directory_focused = directory_start }
;;

(* A known session save may change size/times, not entry identity. Keep pending
   directory proposals compatible with those writes without adopting replacements. *)
let refresh_tracked_resource t path =
  match Option.try_with (fun () -> Directory_buffer.fingerprint path) with
  | None -> t
  | Some ((dev, ino, kind, _, _, _) as actual) ->
    { t with directories = List.map t.directories ~f:(fun d ->
      let name = Filename.basename path in
      if not (String.equal d.path (Filename.dirname path)) then d else
      match Map.find d.fingerprints name with
      | Some (old_dev, old_ino, old_kind, _, _, _)
        when dev = old_dev && ino = old_ino && Poly.equal kind old_kind ->
        { d with fingerprints = Map.set d.fingerprints ~key:name ~data:actual }
      | _ -> d) }
;;

let replace_active t controller =
  let controller, clipboard = Controller.take_clipboard controller in
  let controller, saved = Controller.take_saved controller in
  let t = { t with
    buffers = List.map t.buffers ~f:(fun b -> if not t.directory_focused && Option.equal Buffer_id.equal t.active (Some b.id) then { b with controller } else b)
  ; directories = List.map t.directories ~f:(fun d -> if t.directory_focused && Option.equal Buffer_id.equal t.directory (Some d.id) then { d with controller } else d)
  ; feedback = Controller.feedback controller
  ; register = Editor.unnamed_register (Controller.editor controller)
  ; clipboard = Option.first_some clipboard t.clipboard
  ; saved = t.saved @ Option.to_list saved } in
  Option.value_map saved ~default:t ~f:(fun saved -> refresh_tracked_resource t saved.path)
;;

let install t c = Controller.with_register (Controller.with_feedback c t.feedback) t.register
let dispose t = List.iter t.buffers ~f:(fun b -> Controller.close b.controller); List.iter t.directories ~f:(fun d -> Controller.close d.controller)
let notify t text =
  { t with feedback = Feedback.apply t.feedback (Notify { source = "session"; scope = None; severity = Error; text; history = true }) }
;;
let recoverable t = List.filter t.buffers ~f:(fun b -> Editor.is_dirty (Controller.editor b.controller) || Controller.is_missing b.controller)
let dirty_directories t = List.filter t.directories ~f:Directory_buffer.is_dirty
let relocate moves path =
  Option.value (List.find_map moves ~f:(fun (source, destination) ->
    if String.equal path source then Some destination
    else if String.is_prefix path ~prefix:(source ^ "/")
    then Some (destination ^ String.drop_prefix path (String.length source)) else None)) ~default:path
;;

let check_resource_moves t moves =
  Or_error.try_with (fun () ->
    let paths = List.filter_map t.buffers ~f:(fun b -> Editor.path (Controller.editor b.controller))
      @ List.map t.directories ~f:(fun d -> d.path) in
    let destinations = List.map paths ~f:(relocate moves) in
    List.iter moves ~f:(fun (_, destination) ->
      if List.exists paths ~f:(fun path ->
        (String.equal path destination || String.is_prefix path ~prefix:(destination ^ "/"))
        && String.equal (relocate moves path) path)
      then failwith "Rename destination belongs to an already open resource; close that buffer first");
    if Set.length (String.Set.of_list destinations) <> List.length destinations
    then failwith "Rename conflicts with an already open resource; close that buffer first")
;;

let reconcile_paths t moves =
  let next = ref t.next_generation in
  let closed = ref t.closed in
  let feedback = ref t.feedback in
  let buffers = List.map t.buffers ~f:(fun b ->
    match Editor.path (Controller.editor b.controller) with
    | None -> b
    | Some path ->
      let destination = relocate moves path in
      if String.equal path destination then b else (
        closed := !closed @ [ path ];
        feedback := List.fold (Feedback.Diagnostics.collections (Feedback.diagnostics !feedback))
          ~init:(Feedback.forget_resource !feedback path) ~f:(fun feedback collection ->
            if String.equal (normalize t collection.resource) path
            then Feedback.forget_resource feedback collection.resource else feedback);
        let generation = !next in incr next;
        { b with controller = Controller.reassociate b.controller destination; generation })) in
  let resources = List.fold buffers ~init:String.Map.empty ~f:(fun resources b ->
    Option.value_map (Editor.path (Controller.editor b.controller)) ~default:resources
      ~f:(fun path -> Map.set resources ~key:path ~data:b.id)) in
  let directories = List.map t.directories ~f:(fun d ->
    let path = relocate moves d.path in
    if String.equal path d.path then d else
      { d with path; controller = Controller.reassociate d.controller path }) in
  { t with buffers; resources; directories; closed = !closed; feedback = !feedback
    ; saved = List.map t.saved ~f:(fun saved -> { saved with Controller.Saved.path = relocate moves saved.path })
    ; next_generation = !next; startup_directory = relocate moves t.startup_directory }
;;

let directory_save ?before_mutation t d =
  match Directory_buffer.plan d with
  | Error error -> notify t ("Invalid directory plan: " ^ Error.to_string_hum error)
  | Ok operations ->
    let moves = List.filter_map operations ~f:(function
      | Directory_plan.Rename r -> Some (normalize t (Filename.concat d.path r.source), Resource.normalize ~cwd:d.path r.destination)
      | _ -> None) in
    let coordination = Or_error.bind (check_resource_moves t moves) ~f:(fun () -> Or_error.try_with (fun () ->
      List.iter operations ~f:(fun operation ->
        let destination = match operation with
          | Directory_plan.Rename r -> Some r.destination | Copy r -> Some r.destination | _ -> None in
        Option.iter destination ~f:(fun name ->
          let path = Resource.normalize ~cwd:d.path name in
          if (match operation with Copy _ -> true | _ -> false) &&
            (Map.mem t.resources path || List.exists t.directories ~f:(fun other -> String.equal other.path path))
          then failwith "Copy destination belongs to an open resource; close it first";
          List.iter t.directories ~f:(fun other ->
            if not (Buffer_id.equal other.id d.id) && Directory_buffer.is_dirty other &&
              (String.equal other.path (Filename.dirname path) || String.is_prefix (Filename.dirname path) ~prefix:(other.path ^ "/"))
            then failwith "Destination directory has pending edits; save or undo those edits first"));
        match operation with
        | Delete r -> List.iter t.directories ~f:(fun other ->
            if Directory_buffer.is_dirty other && String.equal other.path (Filename.concat d.path r.source)
            then failwith "Deleted directory has pending edits; save or undo them first")
        | _ -> ()))) in
    match coordination with
    | Error error -> notify t (Error.to_string_hum error)
    | Ok () ->
      let reserved_paths = List.filter_map t.buffers ~f:(fun b -> Editor.path (Controller.editor b.controller))
        @ List.map t.directories ~f:(fun d -> d.path) in
      let result = Directory_apply.apply ~reserved_paths ?before_mutation d in
      let t = reconcile_paths t result.moves in
      let t = { t with buffers = List.map t.buffers ~f:(fun b ->
        if Option.exists (Editor.path (Controller.editor b.controller)) ~f:(fun path ->
          List.exists result.deleted ~f:(fun deleted -> String.equal path deleted || String.is_prefix path ~prefix:(deleted ^ "/")))
        then { b with controller = Controller.mark_missing b.controller } else b) } in
      let fresh, refresh_error = if Option.is_some result.error then result.buffer, None else
        match Directory_buffer.load ~previous:result.buffer ~id:d.id ~path:d.path
          ~cell_width:t.cell_width ~keymap_config:t.keymap_config () with
        | Ok fresh -> Controller.close result.buffer.controller; fresh, None
        | Error error -> result.buffer, Some error in
      let t = { t with directories = List.map t.directories ~f:(fun old ->
         if Buffer_id.equal old.id d.id then fresh else old) } in
      let removed, directories = List.partition_tf t.directories ~f:(fun cached ->
        List.exists result.deleted ~f:(String.equal cached.path)) in
      List.iter removed ~f:(fun cached -> Controller.close cached.controller);
      let retained id = not (List.exists removed ~f:(fun cached -> Buffer_id.equal cached.id id)) in
      let t = { t with directories;
        directory = Option.map t.directory ~f:(fun id -> if retained id then id else d.id);
        remembered = Option.map t.remembered ~f:(fun id -> if retained id then id else d.id) } in
      let cache_errors = ref [] in
      let t = List.fold result.affected ~init:t ~f:(fun t path ->
        { t with directories = List.map t.directories ~f:(fun cached ->
          if Buffer_id.equal cached.id d.id || not (String.equal cached.path path) || Directory_buffer.is_dirty cached then cached
          else match Directory_buffer.load ~previous:cached ~id:cached.id ~path:cached.path ~cell_width:t.cell_width ~keymap_config:t.keymap_config () with
            | Ok fresh -> Controller.close cached.controller; fresh
            | Error error -> cache_errors := (cached.path, error) :: !cache_errors; cached) }) in
      let t = if result.completed = 0 then t else List.fold result.affected ~init:t ~f:refresh_tracked_resource in
      let text = Directory_plan.summary operations ^
        (match result.error with None -> "; directory saved" | Some error ->
          sprintf "; apply stopped after %d mutations: %s; actual backing paths reconciled; unresolved edits retained, save to retry"
            result.completed (Error.to_string_hum error)) ^
         Option.value_map refresh_error ~default:"" ~f:(fun error ->
           "; applied baseline retained, listing refresh failed: " ^ Error.to_string_hum error ^ "; refresh with Space r") ^
         String.concat (List.map !cache_errors ~f:(fun (path, error) ->
           "; affected listing refresh failed for " ^ Directory_identity.encode_name path ^ ": " ^ Error.to_string_hum error ^ "; visit it and refresh with Space r")) in
      let t = if Option.is_none result.error then t else
        let t = List.fold result.moves ~init:t ~f:(fun t (source, destination) ->
          notify t ("Actual backing: " ^ Directory_identity.encode_name (Filename.basename source)
            ^ " -> " ^ Directory_identity.encode_name (Filename.basename destination))) in
        let t = if List.is_empty result.applied then t else
          notify t ("Completed mutations: " ^ Directory_plan.summary result.applied) in
        match Directory_buffer.plan result.buffer with
        | Ok remaining -> notify t ("Remaining intent: " ^ Directory_plan.summary remaining)
        | Error _ -> t in
      { t with feedback = Feedback.apply t.feedback (Notify { source = "session"; scope = Some d.path
        ; severity = (if Option.is_none result.error && Option.is_none refresh_error && List.is_empty !cache_errors then Info else Error); text; history = true }) }
;;
let names bs = String.concat ~sep:", " (List.map bs ~f:(fun b -> Option.value (Controller.display_path b.controller) ~default:"[unnamed]"))

let finish_context t =
  match active_controller t with
  | None -> t
  | Some c ->
    let command = match Editor.mode (Controller.editor c) with
      | Insert -> Some Command.Exit_insert
      | Visual _ -> Some Command.Exit_visual
      | Normal -> None in
    let c = match command with None -> c | Some command -> let c, _, _ = Controller.dispatch (install t c) [ Editor command ] in c in
    replace_active t (Controller.cancel_pending c)
;;

let activate t id =
  if t.exited then Or_error.error_string "Session has exited"
  else match find t id with
  | None -> Or_error.error_string "Buffer is not open"
   | Some _ when Option.equal Buffer_id.equal t.active (Some id) && not t.directory_focused -> Ok t
  | Some _ ->
    let t = finish_context t in
    let t = { t with active = Some id; directory = (match t.placement with Major -> None | Side -> t.directory)
      ; directory_focused = false; empty_keymap = Keymap.reset t.empty_keymap } in
    Ok (replace_active t (Controller.cancel_pending (install t (Option.value_exn (find t id)))))
;;

let open_or_activate t path =
  let path = normalize t path in
  if List.exists t.directories ~f:(fun d -> String.equal d.path path)
  then Or_error.error_string "Resource belongs to a directory buffer; navigate or refresh it instead"
  else match find_resource t path with
  | Some (id, _) -> Or_error.map (activate t id) ~f:(fun t -> t, id)
  | None when t.exited -> Or_error.error_string "Session has exited"
  | None ->
    Or_error.bind (Controller.open_file ~keymap_config:t.keymap_config ~cell_width:t.cell_width path) ~f:(fun controller ->
      let id = Buffer_id.of_int t.next_id in
      let t = { t with buffers = t.buffers @ [ { id; controller; generation = t.next_generation } ]; resources = Map.set t.resources ~key:path ~data:id; next_id = t.next_id + 1; next_generation = t.next_generation + 1 } in
      Or_error.map (activate t id) ~f:(fun t -> t, id))
;;

let show_directory ?select t path =
  if t.exited then Or_error.error_string "Session has exited" else
  let path = normalize t path in
  let cached = List.find t.directories ~f:(fun d -> String.equal d.path path) in
  let loaded = if Map.mem t.resources path then Or_error.error_string "Resource belongs to an open file buffer; close it before browsing a replacement directory"
    else match cached with Some d -> Ok d | None ->
    Directory_buffer.load ~id:(Buffer_id.of_int t.next_id) ~path ~cell_width:t.cell_width ~keymap_config:t.keymap_config () in
  Or_error.map loaded ~f:(fun d ->
    let t = finish_context t in
    let d = if Option.is_none cached then d else
      List.find_exn t.directories ~f:(fun old -> Buffer_id.equal old.id d.id) in
    let d = Option.value_map select ~default:d ~f:(Directory_buffer.select d) in
    let d = { d with controller = Controller.cancel_pending d.controller } in
    { t with directories = d :: List.filter t.directories ~f:(fun old -> not (Buffer_id.equal old.id d.id))
      ; directory = Some d.id; remembered = Some d.id; directory_focused = true
      ; return_file = (if Option.is_none t.directory then t.active else t.return_file)
      ; next_id = (if Option.is_none cached then t.next_id + 1 else t.next_id) })
;;

let update_directory t d =
  { t with directories = List.map t.directories ~f:(fun old ->
      if Buffer_id.equal old.id d.Directory_buffer.id then d else old) }
;;

(* Placement/focus changes cancel prefixes, but do not discard the directory's
   selection or editing state. Only explicit file opening finishes Visual. *)
let focus_directory t focused =
  let leaving_insert = Option.exists (active_controller t) ~f:(fun c -> Mode.equal (Editor.mode (Controller.editor c)) Insert) in
  let t = if (focused && not t.directory_focused) || leaving_insert then finish_context t else t in
  let t = match active_controller t with None -> t | Some c -> replace_active t (Controller.cancel_pending c) in
  let focused = focused && Option.is_some t.directory in
  let t = { t with directory_focused = focused } in
  match active_controller t with None -> t | Some c -> replace_active t (Controller.cancel_pending c)
;;

let set_directory_placement t placement =
  let t = { t with placement } in
  match directory_buffer t with
  | Some _ -> focus_directory t true
  | None ->
    let path = Option.value_map t.remembered ~default:t.startup_directory ~f:(fun id ->
      (List.find_exn t.directories ~f:(fun d -> Buffer_id.equal d.id id)).path) in
    (match show_directory t path with Ok t -> t | Error e -> notify t (Error.to_string_hum e))
;;

let hide_directory t =
  if Option.is_none t.active then notify t "No file to return to" else
  let t = focus_directory t false in
  { t with directory = None }
;;

(* Read-only presentation snapshot for rendering the other retained surface. *)
let surface t ~directory =
  if directory then { t with directory_focused = true; placement = Major }
  else { t with directory_focused = false }
;;

(** Both batch sources resolve backing resources in listing order. A duplicate
    resource shares its first outcome, including mark clearing on success. *)
let batch_open t d entries ~clear_marks =
  let t, outcomes, first, opened, failed, skipped =
    List.fold entries ~init:(t, String.Map.empty, None, 0, 0, 0)
      ~f:(fun (t, outcomes, first, opened, failed, skipped) e ->
        let path = normalize t (Filename.concat d.Directory_buffer.path e.Directory_identity.Entry.name) in
        match Map.find outcomes path with
        | Some _ -> t, outcomes, first, opened, failed, skipped
        | None ->
          let outcome, t, first =
            if Directory_buffer.is_directory path || Directory_identity.Kind.equal e.kind Unsupported
            then `Skipped, notify t ("Batch skipped: " ^ Directory_identity.encode_name e.name), first
            else match Or_error.bind (Or_error.try_with (fun () ->
              if not (Poly.equal (Core_unix.stat path).st_kind Core_unix.S_REG)
              then failwith "Unsupported file kind")) ~f:(fun () -> open_or_activate t path) with
              | Ok (t, id) -> `Opened, t, Option.first_some first (Some id)
              | Error error -> `Failed, notify t (Directory_identity.encode_name e.name ^ ": " ^ Error.to_string_hum error), first in
          t, Map.set outcomes ~key:path ~data:outcome, first,
          opened + (if Poly.equal outcome `Opened then 1 else 0),
          failed + (if Poly.equal outcome `Failed then 1 else 0),
          skipped + (if Poly.equal outcome `Skipped then 1 else 0)) in
  (* Fetch the retained controller: successful opening finished its Visual context. *)
  let retained = List.find_exn t.directories ~f:(fun old -> Buffer_id.equal old.id d.id) in
  let marks = if not clear_marks then retained.marks else
    List.fold entries ~init:retained.marks ~f:(fun marks e ->
      if Option.exists (Map.find outcomes (normalize t (Filename.concat d.path e.name)))
        ~f:(Poly.equal `Opened) then Set.remove marks e.id else marks) in
  let t = update_directory t { retained with marks } in
  let t = Option.value_map first ~default:t ~f:(fun id -> activate t id |> Or_error.ok_exn) in
  { t with feedback = Feedback.apply t.feedback (Notify { source = "session"; scope = None
    ; severity = (if failed = 0 && skipped = 0 then Info else Error)
    ; text = sprintf "Batch open: %d opened, %d failed, %d skipped" opened failed skipped; history = true }) }
;;

let navigation t (view : View_command.t) =
  let result = match view, input_directory t with
    | (Toggle_entry_mark | Mark_selection | Unmark_selection | Open_marked_files | Open_directory_entry), Some d
      when Result.is_error (Directory_buffer.rows d) ->
      Or_error.map (Directory_buffer.rows d) ~f:(fun _ -> t)
    | (Toggle_entry_mark | Mark_selection), Some d
      when List.exists (if View_command.equal view Toggle_entry_mark then
          Option.to_list (Directory_buffer.selected_row d) else Directory_buffer.selection_rows d)
        ~f:(fun r -> match r.Directory_identity.Row.identity with Existing _ -> false | Fresh | Copy _ -> true) ->
      Or_error.error_string "New rows require save before marking/opening"
    | Toggle_entry_mark, Some d -> Ok (update_directory t (Directory_buffer.toggle_mark d))
    | Mark_selection, Some d -> Ok (update_directory t (Directory_buffer.mark_selection d ~marked:true))
    | Unmark_selection, Some d -> Ok (update_directory t (Directory_buffer.mark_selection d ~marked:false))
    | Clear_directory_marks, Some d -> Ok (update_directory t { d with marks = Int.Set.empty })
    | Open_marked_files, Some d -> Ok (batch_open t d (Directory_buffer.marked_entries d) ~clear_marks:true)
    | Open_directory_entry, Some d when Option.is_some (Editor.selection (Controller.editor d.controller)) ->
      let fresh = List.count (Directory_buffer.selection_rows d) ~f:(fun r -> match r.Directory_identity.Row.identity with Existing _ -> false | Fresh | Copy _ -> true) in
      let t = batch_open t d (Directory_buffer.selection_entries d) ~clear_marks:false in
      Ok (if fresh = 0 then t else notify t (sprintf "%d new rows require save before opening" fresh))
    | View_command.Toggle_directory, None ->
      let path = Option.bind (active_controller t) ~f:(fun c -> Editor.path (Controller.editor c)) in
      let parent = Option.value_map path ~default:t.startup_directory ~f:Filename.dirname in
      show_directory ?select:(Option.map path ~f:Filename.basename) { t with return_file = t.active } parent
    | Toggle_directory, Some _ ->
      (match Option.first_some (Option.filter t.return_file ~f:(fun id -> Option.is_some (find t id))) t.active with
       | Some id -> activate t id
       | None -> Ok (notify t "No file to return to"))
    | Directory_parent, Some d -> show_directory ~select:(Filename.basename d.path) t (Filename.dirname d.path)
    | Refresh_directory, Some d ->
      Or_error.map (Directory_buffer.load ~previous:d ~id:d.id ~path:d.path ~cell_width:t.cell_width ~keymap_config:t.keymap_config ()) ~f:(fun fresh ->
        Controller.close d.controller;
        { t with directories = fresh :: List.filter t.directories ~f:(fun old -> not (Buffer_id.equal old.id d.id)) })
    | Open_directory_entry, Some d ->
      (match Directory_buffer.selected d with
       | None -> Ok (notify t (if Option.is_some (Directory_buffer.selected_row d)
           then "New row requires save before opening" else "No entry on this row"))
       | Some e ->
         let path = Filename.concat d.path e.name in
         if Directory_buffer.is_directory path then show_directory t path
         else if Directory_identity.Kind.equal e.kind Unsupported then Or_error.error_string ("Unsupported entry: " ^ Directory_identity.encode_name e.name)
         else Or_error.bind (Or_error.try_with (fun () ->
           if not (Poly.equal (Core_unix.stat path).st_kind Core_unix.S_REG) then failwith "Unsupported file kind"))
           ~f:(fun () -> Or_error.map (open_or_activate t path) ~f:fst))
    | _ -> Ok t in
  match result with Ok t -> t | Error error -> notify t (Error.to_string_hum error)
;;

let quit t ~force =
  if t.exited then t, Controller.Status.Exit else
  let dirty = recoverable t in
  let directories = dirty_directories t in
  if not force && (not (List.is_empty dirty) || not (List.is_empty directories))
  then notify t ("Unsaved changes: " ^ String.concat ~sep:", "
    (List.filter [ names dirty; String.concat ~sep:", " (List.map directories ~f:(fun d -> Directory_identity.encode_name d.path)) ] ~f:(fun s -> not (String.is_empty s)))
    ^ "; save them or force quit (Space Q)"), Controller.Status.Running
  else (dispose t; { t with exited = true }, Controller.Status.Exit)
;;

let save_as t id path =
  let path = normalize t path in
  match find t id with
  | None -> Or_error.error_string "File buffer is not open"
  | Some controller ->
    if Map.mem t.resources path && not (Option.equal Buffer_id.equal (Map.find t.resources path) (Some id))
      || List.exists t.directories ~f:(fun d -> String.equal d.path path)
    then Or_error.error_string "Save-as destination belongs to another open resource" else
    Or_error.map (Controller.save_as (install t controller) path) ~f:(fun controller ->
      let t = Option.value_map (Editor.path (Controller.editor (Option.value_exn (find t id)))) ~default:t
        ~f:(fun old -> reconcile_paths t [ old, path ]) in
      let active = t.active and directory_focused = t.directory_focused in
      let t = replace_active { t with active = Some id; directory_focused = false } controller in
      let directories = List.map t.directories ~f:(fun d ->
        if Directory_buffer.is_dirty d || not (String.equal d.path (Filename.dirname path)) then d else
        match Directory_buffer.load ~previous:d ~id:d.id ~path:d.path ~cell_width:t.cell_width ~keymap_config:t.keymap_config () with
        | Ok fresh -> Controller.close d.controller; fresh | Error _ -> d) in
      { t with active; directory_focused; directories; resources = Map.set t.resources ~key:path ~data:id })
;;

let recreate_current t =
  match active_controller t with
  | None -> notify t "No file buffer to recreate"
  | Some _ when t.directory_focused -> notify t "Recreate targets a missing file tab, not a directory"
  | Some c ->
    match Controller.recreate (install t c) with
    | Error error -> notify t (Error.to_string_hum error)
    | Ok c ->
      let t = replace_active t c in
      { t with directories = List.map t.directories ~f:(fun d ->
        if Directory_buffer.is_dirty d || not (Option.exists (Editor.path (Controller.editor c))
          ~f:(fun path -> String.equal (Filename.dirname path) d.path)) then d else
        match Directory_buffer.load ~previous:d ~id:d.id ~path:d.path ~cell_width:t.cell_width ~keymap_config:t.keymap_config () with
        | Ok fresh -> Controller.close d.controller; fresh
        | Error _ -> d) }
;;

let rec dispatch t actions =
  if t.exited then t, [], Controller.Status.Exit
  else match actions with
  | [] -> t, [], Controller.Status.Running
  | Keymap.Action.View Recreate_missing_file :: rest -> dispatch (recreate_current t) rest
   | Keymap.Action.View (Toggle_directory | Open_directory_entry | Directory_parent | Refresh_directory
       | Toggle_entry_mark | Mark_selection | Unmark_selection | Clear_directory_marks | Open_marked_files as view) :: rest ->
    dispatch (navigation t view) rest
  | Keymap.Action.Editor (Quit | Force_quit as command) :: rest ->
    let t, status = quit t ~force:(Command.equal command Force_quit) in
    if Controller.Status.equal status Exit then t, [], status else dispatch t rest
  | Keymap.Action.Editor Save :: rest when t.directory_focused ->
    let t = Option.value_map (input_directory t) ~default:t ~f:(directory_save t) in
    dispatch t rest
  | Keymap.Action.Editor Reload :: rest when t.directory_focused ->
    dispatch (notify t "Directory reload is unavailable; undo edits then refresh (Space r)") rest
  | _ ->
    let prefix, rest = List.split_while actions ~f:(function
      | Keymap.Action.Editor (Quit | Force_quit) -> false
      | Keymap.Action.View Recreate_missing_file -> false
      | Keymap.Action.Editor (Save | Reload) when t.directory_focused -> false
      | Keymap.Action.View (Toggle_directory | Open_directory_entry | Directory_parent | Refresh_directory
          | Toggle_entry_mark | Mark_selection | Unmark_selection | Clear_directory_marks | Open_marked_files) -> false
      | _ -> true) in
    let rejected = t.directory_focused && List.exists prefix ~f:(function
      | Keymap.Action.Editor command -> not (Directory_buffer.allows command)
      | View _ -> false) in
    let t = if rejected then notify t "Directory action unavailable" else t in
    let prefix = if not t.directory_focused then prefix else List.filter prefix ~f:(function
      | Keymap.Action.Editor command -> Directory_buffer.allows command
      | View _ -> true) in
    let t, views = match active_controller t with
      | None -> t, List.filter_map prefix ~f:(function Keymap.Action.View view -> Some view | Editor _ -> None)
      | Some c ->
        let c, views, _ = Controller.dispatch (install t c) prefix in
        replace_active t c, views in
    let t, tail, status = dispatch t rest in
    t, views @ tail, status
;;

let handle_input t input =
  match active_controller t with
  | None ->
    let empty_keymap, actions = Keymap.feed t.empty_keymap ~mode:Normal input in
    dispatch { t with empty_keymap } actions
  | Some c -> let c, actions = Controller.feed_input (install t c) input in dispatch (replace_active t c) actions
;;

let save_current t = let t, _, _ = dispatch t [ Editor Save ] in t
let save_all t =
  if t.exited then t, [] else
  let original = t.active in
  let directory = t.directory in
  let directory_focused = t.directory_focused in
   let targets = List.map (recoverable t) ~f:(fun b -> b.id, `File b)
    @ List.map (dirty_directories t) ~f:(fun d -> d.id, `Directory d)
    |> List.sort ~compare:(fun (a, _) (b, _) -> Buffer_id.compare a b) in
  let t, results = List.fold targets ~init:(t, []) ~f:(fun (t, results) (id, target) ->
    match target with
    | `Directory _ ->
      let d = List.find_exn t.directories ~f:(fun d -> Buffer_id.equal d.id id) in
      let t = directory_save t d in
      let d = List.find_exn t.directories ~f:(fun d -> Buffer_id.equal d.id id) in
      t, results @ [ id, not (Directory_buffer.is_dirty d) ]
    | `File original ->
      let b = List.find_exn t.buffers ~f:(fun b -> Buffer_id.equal b.id original.id) in
      let c, _, _ = Controller.dispatch (install t b.controller) [ Editor Save ] in
      let t = replace_active { t with active = Some b.id; directory = None; directory_focused = false } c in
       t, results @ [ id, not (Controller.is_missing c || Editor.is_dirty (Controller.editor c)) ]) in
  let failures = List.count results ~f:(fun (_, ok) -> not ok) in
  let feedback = Feedback.apply t.feedback (Notify { source = "session"; scope = None
    ; severity = (if failures = 0 then Info else Error)
    ; text = sprintf "Save all: %d saved, %d failed" (List.length results - failures) failures; history = true }) in
  { t with active = original; directory; directory_focused; feedback }, results
;;

let close_buffer t id ~force =
  if t.exited then t, false else
  match find t id with
  | None ->
    (match List.find t.directories ~f:(fun d -> Buffer_id.equal d.id id) with
     | None -> t, false
     | Some d when Directory_buffer.is_dirty d && not force ->
        notify t ("Unsaved directory: " ^ Directory_identity.encode_name d.path ^ "; save/retry, undo edits, or explicitly force close"), false
     | Some d ->
       Controller.close d.controller;
       let t = { t with directories = List.filter t.directories ~f:(fun old -> not (Buffer_id.equal old.id id))
         ; directory = Option.filter t.directory ~f:(fun current -> not (Buffer_id.equal current id))
         ; remembered = Option.filter t.remembered ~f:(fun current -> not (Buffer_id.equal current id)) } in
       let t = { t with directory_focused = t.directory_focused && Option.is_some t.directory } in
       let t = if Option.is_some t.active || Option.is_some t.directory then t else
         match show_directory t t.startup_directory with Ok t -> t | Error e -> notify t (Error.to_string_hum e) in
       t, true)
   | Some c when (Controller.is_missing c || Editor.is_dirty (Controller.editor c)) && not force ->
    notify t ("Unsaved buffer: " ^ Option.value (Editor.path (Controller.editor c)) ~default:"[unnamed]" ^ "; save it (Space w) or force close (Space b C)"), false
  | Some c ->
    let was_active = Option.equal Buffer_id.equal t.active (Some id) in
    let t = if was_active then finish_context t else t in
    Controller.close c;
    let index = List.findi_exn t.buffers ~f:(fun _ b -> Buffer_id.equal b.id id) |> fst in
    let buffers = List.filter t.buffers ~f:(fun b -> not (Buffer_id.equal b.id id)) in
    let active = if Option.equal Buffer_id.equal t.active (Some id)
      then (if List.is_empty buffers then None else Option.map (List.nth buffers (Int.min index (List.length buffers - 1))) ~f:(fun b -> b.id)) else t.active in
    let resources = Option.value_map (Editor.path (Controller.editor c)) ~default:t.resources ~f:(fun path -> Map.remove t.resources path) in
    let feedback = Option.value_map (Editor.path (Controller.editor c)) ~default:t.feedback ~f:(fun resource ->
      List.fold (Feedback.Diagnostics.collections (Feedback.diagnostics t.feedback)) ~init:(Feedback.forget_resource t.feedback resource)
        ~f:(fun feedback collection -> if String.equal (normalize t collection.resource) resource
          then Feedback.forget_resource feedback collection.resource else feedback)) in
    let t = { t with buffers; resources; active; feedback
      ; empty_keymap = (if was_active then Keymap.reset t.empty_keymap else t.empty_keymap)
      ; closed = t.closed @ Option.to_list (Editor.path (Controller.editor c)) } in
    let t = if not was_active then t else match active_controller t with None -> t | Some c -> replace_active t (Controller.cancel_pending (install t c)) in
    let t = if Option.is_none t.active && Option.is_some t.directory then focus_directory t true else t in
    let t = if Option.is_some t.active || Option.is_some t.directory then t else
      let path = Option.value_map t.remembered ~default:t.startup_directory ~f:(fun id ->
        (List.find_exn t.directories ~f:(fun d -> Buffer_id.equal d.id id)).path) in
      match show_directory t path with Ok t -> t | Error error -> notify t (Error.to_string_hum error) in
    t, true
;;
let close_current t ~force = match t.active with None -> t, false | Some id -> close_buffer t id ~force
let feedback t = t.feedback
let take_clipboard t = { t with clipboard = None }, t.clipboard
let take_saved t = { t with saved = [] }, t.saved
let take_closed t = { t with closed = [] }, t.closed

module For_testing = struct
  let save_directory t id ~before_mutation =
    let d = List.find_exn t.directories ~f:(fun d -> Buffer_id.equal d.id id) in
    directory_save ~before_mutation t d
  ;;
end
