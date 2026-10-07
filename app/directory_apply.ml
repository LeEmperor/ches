open! Core
open Ches_core

external rename_noreplace : string -> string -> unit = "ches_rename_noreplace"
let stage_serial = ref 0

type result =
  { buffer : Directory_buffer.t
  ; moves : (string * string) list
  ; deleted : string list
  ; affected : string list
  ; completed : int
  ; applied : Directory_plan.operation list
  ; error : Error.t option
  }

let apply ?(reserved_paths = []) ?(before_mutation = fun _ -> ())
    ?(before_copy_publish = fun _ -> ()) (original : Directory_buffer.t) =
  let current = ref original in
  let completed = ref 0 in
  let applied = ref [] in
  let rows : Directory_identity.Row.t list ref = ref [] in
  let deleted = ref [] in
  let external_moves = ref [] in
  let affected = ref [ original.path ] in
  let parents = ref String.Map.empty in
  let child name = Resource.normalize ~cwd:original.path name in
  let local name = String.equal (Filename.dirname (child name)) original.path in
  let rec validate_copy path =
    match (Core_unix.lstat path).st_kind with
    | S_REG | S_LNK -> ()
    | S_DIR -> Array.iter (Stdlib.Sys.readdir path) ~f:(fun n -> validate_copy (Filename.concat path n))
    | _ -> failwith "Copy contains an unsupported filesystem kind" in
  let rec remove_owned path =
    if Poly.equal (Core_unix.lstat path).st_kind Core_unix.S_DIR then (
      Core_unix.chmod path ~perm:0o700;
      Array.iter (Stdlib.Sys.readdir path) ~f:(fun n -> remove_owned (Filename.concat path n));
      Core_unix.rmdir path)
    else Core_unix.unlink path in
  let rec copy_tree source destination =
    let stat = Core_unix.lstat source in
    match stat.st_kind with
    | S_LNK -> Core_unix.symlink ~target:(Core_unix.readlink source) ~link_name:destination
    | S_DIR ->
      Core_unix.mkdir ~perm:0o700 destination;
      Array.iter (Stdlib.Sys.readdir source) ~f:(fun n -> copy_tree (Filename.concat source n) (Filename.concat destination n));
      Core_unix.chmod destination ~perm:(stat.st_perm land 0o777)
    | S_REG ->
      let input = Core_unix.openfile source ~mode:[ O_RDONLY ] ~perm:0 in
      Exn.protect ~finally:(fun () -> Core_unix.close input) ~f:(fun () ->
        let output = Core_unix.openfile destination ~mode:[ O_WRONLY; O_CREAT; O_EXCL ] ~perm:0o600 in
        Exn.protect ~finally:(fun () -> Core_unix.close output) ~f:(fun () ->
          let bytes = Bytes.create 65536 in
          let rec loop () =
            let n = Core_unix.read input ~buf:bytes in
            if n > 0 then (
              let rec write pos = if pos < n then
                let count = Core_unix.write output ~buf:bytes ~pos ~len:(n - pos) in
                if count = 0 then failwith "Copy write made no progress" else write (pos + count) in
              write 0; loop ()) in
          loop ();
          Core_unix.fchmod output ~perm:(stat.st_perm land 0o777)))
    | _ -> failwith "Unsupported copy kind" in
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
  let check_parents () =
    check_parent ();
    Map.iteri !parents ~f:(fun ~key:path ~data:identity ->
      let stat = Core_unix.stat path in
      if not (Poly.equal identity (stat.st_dev, stat.st_ino)) then failwith "Destination parent was externally replaced") in
  let mutate f =
    before_mutation (!completed + 1);
    check_parents ();
    f () in
  let move id source destination =
    mutate (fun () ->
      check_entry source;
      absent destination;
      rename_noreplace (child source) (child destination);
      incr completed;
       applied := !applied @ [ Directory_plan.Rename { id; source; destination } ];
       affected := Filename.dirname (child destination) :: !affected;
      (* Record the actual name immediately, before any fallible post-IO work. *)
      let d = !current in
       current := { d with entries = List.filter_map d.entries ~f:(fun e ->
         if e.id <> id then Some e else if local destination then Some { e with name = Filename.basename (child destination) } else None)
        ; fingerprints = Map.set (Map.remove d.fingerprints source) ~key:destination
            ~data:(Map.find_exn d.fingerprints source) };
       if not (local destination) then (
         external_moves := !external_moves @ [ id, child destination ];
         rows := List.filter !rows ~f:(fun row -> not (Directory_identity.Row.equal_identity row.identity (Existing id))));
       if local destination then rows := List.map !rows ~f:(fun row ->
         if Directory_identity.Row.equal_identity row.identity (Existing id) && String.equal (child row.name) (child destination)
         then { row with name = Filename.basename (child destination) } else row);
       current := { !current with fingerprints = Map.set (!current).fingerprints ~key:destination
        ~data:(Directory_buffer.fingerprint (child destination)) }) in
  let error = Or_error.try_with (fun () ->
    let operations = Directory_buffer.plan original |> Or_error.ok_exn in
    rows := Directory_buffer.rows original |> Or_error.ok_exn;
    check_parent ();
    let destination name =
      let path = child name in
      let parent = Core_unix.stat (Filename.dirname path) in
      parents := Map.set !parents ~key:(Filename.dirname path) ~data:(parent.st_dev, parent.st_ino);
      if not (Poly.equal parent.st_kind Core_unix.S_DIR) then failwith "Destination parent is not a directory";
      if String.equal path original.path || String.is_prefix original.path ~prefix:(path ^ "/") then
        failwith "Destination cannot replace this directory or its ancestor";
      path in
    let reject_directory_descendant source destination =
      let source_stat = Core_unix.lstat (child source) in
      if Poly.equal source_stat.st_kind Core_unix.S_DIR then (
        let rec check path =
          let stat = Core_unix.stat path in
          if Poly.equal (source_stat.st_dev, source_stat.st_ino) (stat.st_dev, stat.st_ino)
          then failwith "Directory destination resolves inside its source (including symlink aliases)";
          let parent = Filename.dirname path in
          if not (String.equal parent path) then check parent in
        check (Filename.dirname (child destination))) in
    let sources = List.filter_map operations ~f:(function
      | Directory_plan.Rename r -> Some (child r.source) | _ -> None) |> String.Set.of_list in
    let destinations = List.filter_map operations ~f:(function
      | Rename r -> Some (destination r.destination)
      | Copy r -> Some (destination r.destination)
      | Create_file n | Create_directory n -> Some (destination n)
      | Delete _ -> None) in
    if List.contains_dup destinations ~compare:String.compare then failwith "Duplicate normalized destinations";
    List.iter destinations ~f:(fun path ->
      List.iter operations ~f:(function
        | Rename r when String.is_prefix path ~prefix:(child r.source ^ "/") ->
          failwith "Destination parent is part of a moved source; use separate saves"
        | Delete r when String.is_prefix path ~prefix:(child r.source ^ "/") ->
          failwith "Destination parent is part of a deleted source"
        | _ -> ()));
    (* Entire preflight must succeed before any mutation. *)
    List.iter operations ~f:(function
      | Rename r ->
        check_entry r.source;
        reject_directory_descendant r.source r.destination;
        if String.is_prefix (child r.destination) ~prefix:(child r.source ^ "/") then failwith "Cannot move an entry into itself";
        if (Core_unix.stat (Filename.dirname (child r.destination))).st_dev <> fst original.parent_identity
        then failwith "Cross-device moves are unsupported (no copy/delete fallback)";
        if not (Set.mem sources (child r.destination)) then absent r.destination
      | Copy r -> check_entry r.source; validate_copy (child r.source);
        reject_directory_descendant r.source r.destination;
        if String.is_prefix (child r.destination) ~prefix:(child r.source ^ "/") then failwith "Cannot copy an entry into itself";
        absent r.destination
      | Delete r -> check_entry r.source;
        if Directory_identity.Kind.equal r.kind Directory && Array.length (Stdlib.Sys.readdir (child r.source)) <> 0
        then failwith "Permanent deletion supports empty directories only; nonempty directories are refused"
      | Create_file name | Create_directory name -> if not (Set.mem sources (child name)) then absent name);
    List.iter operations ~f:(function
      | Copy r as operation -> mutate (fun () ->
        check_entry r.source; absent r.destination;
        affected := Filename.dirname (child r.destination) :: !affected;
        let temp = Core_unix.mkdtemp (Filename.concat (Filename.dirname (child r.destination)) ".ches-copy-") in
        let owned = Core_unix.lstat temp in
        Exn.protect ~finally:(fun () ->
          (* A replaced parent must not turn cleanup into deletion of an unrelated
             tree at the same lexical path. An externally relocated private tree
             cannot safely be recovered by path lookup. *)
          match Option.try_with (fun () -> Core_unix.lstat temp) with
          | Some actual when Poly.equal (owned.st_dev, owned.st_ino) (actual.st_dev, actual.st_ino) -> remove_owned temp
          | _ -> ()) ~f:(fun () ->
          let payload = Filename.concat temp "payload" in
          copy_tree (child r.source) payload;
          before_copy_publish (child r.destination);
          check_parents ();
          check_entry r.source;
          rename_noreplace payload (child r.destination);
          incr completed; applied := !applied @ [ operation ];
          affected := Filename.dirname (child r.destination) :: !affected;
          let d = !current in
          let id = d.next_entry in
          current := { d with next_entry = id + 1;
            entries = (if local r.destination then d.entries @ [ { Directory_identity.Entry.id; name = Filename.basename (child r.destination); kind = r.kind } ] else d.entries) };
          rows := List.filter_map !rows ~f:(fun row ->
            if Directory_identity.Row.equal_identity row.identity (Copy r.id) && String.equal row.name r.destination
            then if local r.destination then Some { row with identity = Existing id; name = Filename.basename (child r.destination) } else None
            else Some row);
          if local r.destination then current := { !current with fingerprints = Map.set (!current).fingerprints
            ~key:(Filename.basename (child r.destination)) ~data:(Directory_buffer.fingerprint (child r.destination)) }))
      | _ -> ());
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
      | Copy _ -> ()
      | Delete r as operation -> mutate (fun () ->
        check_entry r.source;
        if Directory_identity.Kind.equal r.kind Directory then Core_unix.rmdir (child r.source) else Core_unix.unlink (child r.source);
        incr completed; applied := !applied @ [ operation ]; deleted := child r.source :: !deleted;
        current := { !current with entries = List.filter (!current).entries ~f:(fun e -> e.id <> r.id);
          fingerprints = Map.remove (!current).fingerprints r.source })
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
          applied := !applied @ [ operation ];
          current := { d with entries = d.entries @ [ { Directory_identity.Entry.id; name; kind } ]
            ; next_entry = id + 1 };
          rows := List.map !rows ~f:(fun row ->
            if Directory_identity.Row.equal_identity row.identity Fresh && String.equal row.name name
            then { row with identity = Existing id } else row);
          Option.iter fd ~f:Core_unix.close;
          current := { !current with fingerprints = Map.set (!current).fingerprints ~key:name
            ~data:(Directory_buffer.fingerprint (child name)) }))) |> Result.error in
  List.iter !affected ~f:(fun path ->
    if String.equal (Filename.dirname path) original.path then
      let name = Filename.basename path in
      match Map.find (!current).fingerprints name, Option.try_with (fun () -> Directory_buffer.fingerprint path) with
      | Some old, Some actual when Directory_buffer.same_identity old actual ->
        current := { !current with fingerprints = Map.set (!current).fingerprints ~key:name ~data:actual }
      | _ -> ());
  let d = { !current with marks = Set.filter (!current).marks ~f:(fun id ->
    List.exists (!current).entries ~f:(fun entry -> entry.id = id)) } in
  let moves = List.filter_map original.entries ~f:(fun old ->
    Option.bind (List.find d.entries ~f:(fun e -> e.id = old.id)) ~f:(fun e ->
       if String.equal old.name e.name then None else Some (child old.name, child e.name))) @
    List.map !external_moves ~f:(fun (id, destination) ->
      let old = List.find_exn original.entries ~f:(fun e -> e.id = id) in child old.name, destination) in
  if !completed = 0 && Option.is_some error then { buffer = d; moves; deleted = !deleted; affected = !affected; completed = 0; applied = []; error }
  else
    let baseline = Directory_identity.create d.entries |> Or_error.ok_exn in
    let saved = Directory_identity.text baseline in
    let text = if Option.is_none error then saved else
      let desired = List.map !rows ~f:(fun row ->
        let prefix = match row.Directory_identity.Row.identity with
          | Existing id -> sprintf "@ches[%d]\t" id | Copy id -> sprintf "@copy[%d]\t" id | Fresh -> "" in
        prefix ^ (String.split row.name ~on:'/' |> List.map ~f:Directory_identity.encode_name |> String.concat ~sep:"/") ^
          (if Directory_identity.Kind.equal row.kind Directory then "/" else "")) in
      Text_buffer.of_string (String.concat ~sep:"\n" desired) |> Result.ok |> Option.value_exn in
    let selected = List.find !rows ~f:(fun row ->
      row.Directory_identity.Row.line = Editor.cursor_line (Controller.editor original.controller)) in
    let line = if Option.is_some error then
      List.findi !rows ~f:(fun _ row -> Option.exists selected ~f:(fun chosen -> row.line = chosen.line))
        |> Option.map ~f:fst
      else Option.bind selected ~f:(fun row -> match row.identity with
        | Fresh | Copy _ -> None
        | Existing id -> List.findi d.entries ~f:(fun _ e -> e.id = id) |> Option.map ~f:fst) in
    let controller = Controller.rebase_text d.controller ~saved ~text
      |> fun controller -> Controller.jump controller ~line:(Option.value line ~default:0 + 1) ~column:1 |> Or_error.ok_exn in
    { buffer = { d with baseline; controller }; moves; deleted = !deleted; affected = !affected; completed = !completed; applied = !applied; error }
;;

module For_testing = struct
  let rename_noreplace = rename_noreplace
end
