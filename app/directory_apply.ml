open! Core
open Ches_core

external rename_noreplace : string -> string -> unit = "ches_rename_noreplace"
let stage_serial = ref 0

type result =
  { buffer : Directory_buffer.t
  ; moves : (string * string) list
  ; completed : int
  ; error : Error.t option
  }

let apply ?(reserved_paths = []) ?(before_mutation = fun _ -> ()) (original : Directory_buffer.t) =
  let current = ref original in
  let completed = ref 0 in
  let rows = ref [] in
  let child name = Filename.concat original.path name in
  let check_parent () =
    let s = Core_unix.stat original.path in
    if not (Poly.equal (s.st_dev, s.st_ino) original.parent_identity)
    then failwith "Directory was externally replaced" in
  let check_entry name =
    check_parent ();
    if not (Option.value_map (Map.find (!current).fingerprints name) ~default:false
      ~f:(Poly.equal (Directory_buffer.fingerprint (child name))))
    then failwith ("Entry changed externally: " ^ Directory_identity.encode_name name) in
  let absent name =
    try ignore (Core_unix.lstat (child name)); failwith ("Destination exists: " ^ Directory_identity.encode_name name)
    with Core_unix.Unix_error (Core_unix.ENOENT, _, _) -> () in
  let mutate f =
    before_mutation (!completed + 1);
    check_parent ();
    f () in
  let move id source destination =
    mutate (fun () ->
      check_entry source;
      absent destination;
      rename_noreplace (child source) (child destination);
      incr completed;
      (* Record the actual name immediately, before any fallible post-IO work. *)
      let d = !current in
      current := { d with entries = List.map d.entries ~f:(fun e ->
        if e.id = id then { e with name = destination } else e)
        ; fingerprints = Map.set (Map.remove d.fingerprints source) ~key:destination
            ~data:(Map.find_exn d.fingerprints source) };
      current := { !current with fingerprints = Map.set (!current).fingerprints ~key:destination
        ~data:(Directory_buffer.fingerprint (child destination)) }) in
  let error = Or_error.try_with (fun () ->
    let operations = Directory_buffer.plan original |> Or_error.ok_exn in
    rows := Directory_buffer.rows original |> Or_error.ok_exn;
    check_parent ();
    let sources = List.filter_map operations ~f:(function
      | Directory_plan.Rename r -> Some r.source | _ -> None) |> String.Set.of_list in
    (* Entire preflight must succeed before any mutation. *)
    List.iter operations ~f:(function
      | Rename r -> check_entry r.source; if not (Set.mem sources r.destination) then absent r.destination
      | Create_file name | Create_directory name -> if not (Set.mem sources name) then absent name);
    let staged = List.filter_map operations ~f:(function
      | Rename r ->
        let rec choose () =
          incr stage_serial;
          let name = sprintf ".ches-stage-%d-%d" (Pid.to_int (Core_unix.getpid ())) !stage_serial in
          if List.exists !rows ~f:(fun row -> String.equal row.Directory_identity.Row.name name)
            || List.exists reserved_paths ~f:(fun path -> String.equal path (child name)
              || String.is_prefix path ~prefix:(child name ^ "/"))
            || (try ignore (Core_unix.lstat (child name)); true
                with Core_unix.Unix_error (Core_unix.ENOENT, _, _) -> false)
          then choose () else name in
        let temporary = choose () in
        move r.id r.source temporary;
        Some (r.id, temporary, r.destination)
      | _ -> None) in
    List.iter staged ~f:(fun (id, temporary, destination) -> move id temporary destination);
    List.iter operations ~f:(function
      | Rename _ -> ()
      | Create_file name | Create_directory name as operation ->
        mutate (fun () ->
          absent name;
          let kind, fd = match operation with
            | Create_directory _ -> Core_unix.mkdir ~perm:0o777 (child name); Directory_identity.Kind.Directory, None
            | _ ->
              let fd = Core_unix.openfile (child name) ~mode:[ O_WRONLY; O_CREAT; O_EXCL ] ~perm:0o666 in
              Directory_identity.Kind.File, Some fd in
          let d = !current in
          let id = d.next_entry in
          incr completed;
          current := { d with entries = d.entries @ [ { Directory_identity.Entry.id; name; kind } ]
            ; next_entry = id + 1 };
          rows := List.map !rows ~f:(fun row ->
            if Directory_identity.Row.equal_identity row.identity Fresh && String.equal row.name name
            then { row with identity = Existing id } else row);
          Option.iter fd ~f:Core_unix.close;
          current := { !current with fingerprints = Map.set (!current).fingerprints ~key:name
            ~data:(Directory_buffer.fingerprint (child name)) }))) |> Result.error in
  let d = !current in
  let moves = List.filter_map original.entries ~f:(fun old ->
    Option.bind (List.find d.entries ~f:(fun e -> e.id = old.id)) ~f:(fun e ->
      if String.equal old.name e.name then None else Some (child old.name, child e.name))) in
  if !completed = 0 && Option.is_some error then { buffer = original; moves; completed = 0; error }
  else
    let baseline = Directory_identity.create d.entries |> Or_error.ok_exn in
    let saved = Directory_identity.text baseline in
    let text = if Option.is_none error then saved else
      let desired = List.map !rows ~f:(fun row ->
        let prefix = match row.Directory_identity.Row.identity with
          | Existing id -> sprintf "@ches[%d]\t" id | Fresh -> "" in
        prefix ^ Directory_identity.encode_name row.name ^
          (if Directory_identity.Kind.equal row.kind Directory then "/" else "")) in
      Text_buffer.of_string (String.concat ~sep:"\n" desired) |> Result.ok |> Option.value_exn in
    let selected = List.find !rows ~f:(fun row ->
      row.Directory_identity.Row.line = Editor.cursor_line (Controller.editor original.controller)) in
    let line = if Option.is_some error then
      List.findi !rows ~f:(fun _ row -> Option.exists selected ~f:(fun chosen -> row.line = chosen.line))
        |> Option.map ~f:fst
      else Option.bind selected ~f:(fun row -> match row.identity with
        | Fresh -> None
        | Existing id -> List.findi d.entries ~f:(fun _ e -> e.id = id) |> Option.map ~f:fst) in
    let controller = Controller.rebase_text d.controller ~saved ~text
      |> fun controller -> Controller.jump controller ~line:(Option.value line ~default:0 + 1) ~column:1 |> Or_error.ok_exn in
    { buffer = { d with baseline; controller }; moves; completed = !completed; error }
;;
