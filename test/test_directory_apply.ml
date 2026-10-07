open! Core
open Ches_core
open Ches_app

let width _ = 1
let child = Filename.concat
let exists path = Option.is_some (Option.try_with (fun () -> Core_unix.lstat path))
let rec remove_fixture path =
  let s = Core_unix.lstat path in
  if Poly.equal s.st_kind Core_unix.S_DIR then (
    Array.iter (Stdlib.Sys.readdir path) ~f:(fun name -> remove_fixture (child path name));
    Core_unix.rmdir path)
  else Core_unix.unlink path
;;
let fixture f =
  let root = Core_unix.mkdtemp "/tmp/opencode/ches-directory-apply-" in
  Exn.protect ~f:(fun () -> f root) ~finally:(fun () -> remove_fixture root)
;;
let write root name text = Out_channel.write_all (child root name) ~data:text
let read root name = In_channel.read_all (child root name)
let load root = Directory_buffer.load ~id:(Buffer_id.of_int 1) ~path:root ~cell_width:width
  ~keymap_config:Ches_input.Keymap.Config.default () |> Or_error.ok_exn
let edit (d : Directory_buffer.t) renames fresh =
  let entries = List.map d.entries ~f:(fun e ->
    { e with name = Option.value (List.Assoc.find renames e.name ~equal:String.equal) ~default:e.name }) in
  let desired = Directory_identity.text (Directory_identity.create entries |> Or_error.ok_exn)
    |> Text_buffer.to_string in
  let text = Text_buffer.of_string (desired ^ "\n" ^ fresh) |> Result.ok |> Option.value_exn in
  { d with controller = Controller.rebase_text d.controller
      ~saved:(Directory_identity.text d.baseline) ~text }
;;
let keys t notation = List.fold (Key_notation.keys notation) ~init:t ~f:(fun t input ->
  let t, _, _ = Session.handle_input t input in t)
let directory t = Session.directory_buffer t |> Option.value_exn
let edit_session t renames fresh =
  let d = edit (directory t) renames fresh in Session.replace_active t d.controller
let start root = Session.create ~cell_width:width (Startup.open_path ~cell_width:width root |> Or_error.ok_exn)

let snapshot (d : Directory_buffer.t) raw =
  { d with controller = Controller.rebase_text d.controller ~saved:(Directory_identity.text d.baseline)
    ~text:(Text_buffer.of_string raw |> Result.ok |> Option.value_exn) }
let row (d : Directory_buffer.t) name destination =
  let entry = List.find_exn d.entries ~f:(fun e -> String.equal e.name name) in
  sprintf "@ches[%d]\t%s%s" entry.id destination (if Directory_identity.Kind.equal entry.kind Directory then "/" else "")
let copy_row (d : Directory_buffer.t) name destination =
  let entry = List.find_exn d.entries ~f:(fun e -> String.equal e.name name) in
  sprintf "@copy[%d]\t%s%s" entry.id destination (if Directory_identity.Kind.equal entry.kind Directory then "/" else "")

let%test_unit "many buffers retain identities and providers until actual close or shutdown" =
  fixture (fun root ->
    List.init 48 ~f:Fn.id |> List.iter ~f:(fun n ->
      let dir = child root (sprintf "dir-%02d" n) in
      Core_unix.mkdir dir; write dir "file.ml" "let x = 1\n");
    let t, opened = List.fold (List.init 48 ~f:Fn.id) ~init:(start root, []) ~f:(fun (t, opened) n ->
      let dir = child root (sprintf "dir-%02d" n) in
      let t = Session.show_directory t dir |> Or_error.ok_exn in
      let directory_id = Session.context_id t |> Option.value_exn in
      let t, id = Session.open_or_activate t (child dir "file.ml") |> Or_error.ok_exn in
      let controller = Session.find t id |> Option.value_exn in
      assert (Controller.For_testing.has_live_highlight_provider controller);
      t, (directory_id, id, controller) :: opened) in
    assert (List.length (Session.buffers t) = 48);
    let t = List.fold opened ~init:t ~f:(fun t (directory_id, id, controller) ->
      assert (Session.has_buffer t directory_id && Session.has_buffer t id);
      let t = Session.activate t id |> Or_error.ok_exn in
      assert (Controller.For_testing.has_live_highlight_provider controller);
      let t, closed = Session.close_buffer t id ~force:false in
      assert closed;
      assert (not (Session.has_buffer t id));
      assert (not (Controller.For_testing.has_live_highlight_provider controller));
      t) in
    assert (List.is_empty (Session.buffers t));
    let t, _ = Session.open_or_activate t (child (child root "dir-00") "file.ml") |> Or_error.ok_exn in
    let controller = Session.active_controller t |> Option.value_exn in
    Session.dispose t; Session.dispose t;
    assert (not (Controller.For_testing.has_live_highlight_provider controller)))
;;

let%test_unit "partial move preserves canonical escapes at destination component edges" =
  fixture (fun root ->
    Core_unix.mkdir (child root "src"); Core_unix.mkdir (child root " other ");
    let src = child root "src" in
    write src "a" "payload";
    let d = load src in
    let raw = row d "a" "../\\x20other\\x20/\\x20name\\x20" in
    let first = Directory_apply.apply (snapshot d raw)
      ~before_mutation:(fun step -> if step = 2 then failwith "stop after staging") in
    assert (first.completed = 1 && Option.is_some first.error);
    assert (Result.is_ok (Directory_buffer.plan first.buffer));
    let retry = Directory_apply.apply first.buffer in
    assert (Option.is_none retry.error);
    assert (String.equal (read (child root " other ") " name ") "payload");
    Controller.close retry.buffer.controller)
;;

let%test_unit "copy publication rechecks its parent and cleanup never removes a replacement tree" =
  fixture (fun root ->
    Core_unix.mkdir (child root "src"); Core_unix.mkdir (child root "dst");
    let src = child root "src" and dst = child root "dst" in
    write src "a" "payload";
    let d = load src in
    let raw = row d "a" "a" ^ "\n" ^ copy_row d "a" "../dst/copy" in
    let first = Directory_apply.apply (snapshot d raw) ~before_copy_publish:(fun _ ->
      let temporary = Array.find_exn (Stdlib.Sys.readdir dst) ~f:(String.is_prefix ~prefix:".ches-copy-") in
      Core_unix.rename ~src:dst ~dst:(child root "retired");
      Core_unix.mkdir dst;
      Core_unix.mkdir (child dst temporary);
      write (child dst temporary) "unrelated" "keep") in
    assert (first.completed = 0 && Option.is_some first.error);
    assert (not (exists (child dst "copy")));
    let temporary = Array.find_exn (Stdlib.Sys.readdir dst) ~f:(String.is_prefix ~prefix:".ches-copy-") in
    assert (String.equal (read (child dst temporary) "unrelated") "keep");
    Controller.close first.buffer.controller)
;;

let%test_unit "phase8 permanent deletion preserves missing clean/dirty buffers and explicit exclusive recovery" =
  fixture (fun root ->
    write root "a" "AAA"; write root "b" "BBB";
    Core_unix.mkdir (child root "empty");
    Core_unix.symlink ~target:"a" ~link_name:(child root "link");
    let t, a = Session.open_or_activate (start root) (child root "a") |> Or_error.ok_exn in
    let t = keys t "iX<Esc>" in
    let t, b = Session.open_or_activate t (child root "b") |> Or_error.ok_exn in
    let t = Session.show_directory t root |> Or_error.ok_exn in
    let d = snapshot (directory t) "" in
    let t = Session.replace_active t d.controller |> Session.save_current in
    assert (not (exists (child root "a")) && not (exists (child root "empty")) && not (exists (child root "link")));
    let ac = Session.find t a |> Option.value_exn and bc = Session.find t b |> Option.value_exn in
    assert (Controller.is_missing ac && Controller.is_missing bc);
    assert (String.equal (Text_buffer.to_string (Editor.text (Controller.editor ac))) "XAAA");
    let t, outcomes = Session.save_all t in
    assert (List.length outcomes = 2 && List.for_all outcomes ~f:(fun (_, ok) -> not ok));
    assert (not (exists (child root "a")));
    let t, closed = Session.close_buffer t b ~force:false in assert (not closed);
    let _, status = Session.quit t ~force:false in assert (Controller.Status.equal status Running);
    let t = Session.activate t a |> Or_error.ok_exn |> fun t -> keys t " br" in
    assert (String.equal (read root "a") "XAAA");
    assert (not (Controller.is_missing (Session.find t a |> Option.value_exn)));
    write root "b" "unrelated";
    let t = Session.activate t b |> Or_error.ok_exn |> Session.recreate_current in
    assert (String.equal (read root "b") "unrelated");
    assert (Controller.is_missing (Session.find t b |> Option.value_exn));
    let t = Session.save_as t b (child root "recovered") |> Or_error.ok_exn in
    assert (String.equal (read root "recovered") "BBB");
    assert (Option.is_none (Session.find_resource t (child root "b")));
    assert (Option.is_some (Session.find_resource t (child root "recovered")));
    Session.dispose t)
;;

let%test_unit "phase8 nonempty delete refuses whole plan and symlink unlink never deletes target" =
  fixture (fun root ->
    Core_unix.mkdir (child root "dir"); write (child root "dir") "nested" "keep";
    write root "file" "keep";
    let d = snapshot (load root) "fresh" in
    let result = Directory_apply.apply d in
    assert (result.completed = 0 && Option.is_some result.error && not (exists (child root "fresh")));
    Core_unix.symlink ~target:"dir" ~link_name:(child root "link");
    let d = load root in
    let desired = String.concat ~sep:"\n" [row d "dir" "dir"; row d "file" "file"] in
    let result = Directory_apply.apply (snapshot d desired) in
    assert (Option.is_none result.error && not (exists (child root "link")));
    assert (String.equal (read (child root "dir") "nested") "keep");
    Controller.close result.buffer.controller)
;;

let%test_unit "phase8 recursive copy preserves contents modes and link bytes, not link targets" =
  fixture (fun root ->
    Core_unix.mkdir (child root "tree"); write (child root "tree") "file" "payload";
    Core_unix.chmod (child (child root "tree") "file") ~perm:0o751;
    Core_unix.symlink ~target:"../missing" ~link_name:(child (child root "tree") "dangling");
    Core_unix.symlink ~target:"tree" ~link_name:(child root "link");
    let d = load root in
    let raw = Text_buffer.to_string (Directory_identity.text d.baseline) ^ "\n" ^
      copy_row d "tree" "replica" ^ "\n" ^ copy_row d "link" "alias" in
    let result = Directory_apply.apply (snapshot d raw) in
    assert (Option.is_none result.error && result.completed = 2);
    assert (String.equal (read (child root "replica") "file") "payload");
    assert ((Core_unix.stat (child (child root "replica") "file")).st_perm = 0o751);
    assert (String.equal (Core_unix.readlink (child (child root "replica") "dangling")) "../missing");
    assert (Poly.equal (Core_unix.lstat (child root "alias")).st_kind Core_unix.S_LNK);
    assert (String.equal (Core_unix.readlink (child root "alias")) "tree");
    Controller.close result.buffer.controller)
;;

let%test_unit "phase8 every copy move delete create failure boundary retains only unresolved intent" =
  List.iter [1; 2; 3; 4; 5; 6] ~f:(fun fail_at -> fixture (fun root ->
    Core_unix.mkdir (child root "src"); Core_unix.mkdir (child root "dst");
    let src = child root "src" and dst = child root "dst" in
    write src "a" "AAA"; write src "remove" "gone";
    let d = load src in
    let raw = String.concat ~sep:"\n" [row d "a" "../dst/moved"; copy_row d "a" "copied"; "fresh"] in
    let first = Directory_apply.apply (snapshot d raw) ~before_mutation:(fun step -> if step = fail_at then failwith "injected phase8 fault") in
    if fail_at <= 5 then assert (first.completed = fail_at - 1 && Option.is_some first.error)
    else assert (Option.is_none first.error);
    List.iter first.moves ~f:(fun (_, path) -> assert (String.equal (In_channel.read_all path) "AAA"));
    let retry = Directory_apply.apply first.buffer in
    assert (Option.is_none retry.error);
    assert (String.equal (read dst "moved") "AAA" && String.equal (read src "copied") "AAA");
    assert (not (exists (child src "remove")) && exists (child src "fresh"));
    assert (not (Directory_buffer.is_dirty retry.buffer));
    assert (not (Array.exists (Stdlib.Sys.readdir src) ~f:(String.is_prefix ~prefix:".ches-")));
    Controller.close retry.buffer.controller))
;;

let%test_unit "phase8 cross-directory move reindexes dirty descendants and refreshes destination cache" =
  fixture (fun root ->
    Core_unix.mkdir (child root "src"); Core_unix.mkdir (child root "dst");
    let src = child root "src" and dst = child root "dst" in
    Core_unix.mkdir (child src "tree"); write (child src "tree") "file" "payload";
    let t, id = Session.open_or_activate (start src) (child (child src "tree") "file") |> Or_error.ok_exn in
    let t = keys t "iX<Esc>" in
    let t = Session.show_directory t (child src "tree") |> Or_error.ok_exn in
    let tree_id = (directory t).id in
    let t = keys t "opending<Esc>" in
    let t = Session.show_directory t dst |> Or_error.ok_exn in
    let dst_id = (directory t).id in
    let t = Session.show_directory t src |> Or_error.ok_exn in
    let d = directory t in
    let t = Session.replace_active t (snapshot d (row d "tree" "../dst/tree")).controller |> Session.save_current in
    let newpath = child (child dst "tree") "file" in
    assert (Option.is_none (Session.find_resource t (child (child src "tree") "file")));
    assert (Option.is_some (Session.find_resource t newpath));
    let t = Session.show_directory t dst |> Or_error.ok_exn in
    assert (Buffer_id.equal (directory t).id dst_id && List.length (directory t).entries = 1);
    let t = Session.show_directory t (child dst "tree") |> Or_error.ok_exn in
    assert (Buffer_id.equal (directory t).id tree_id);
    assert (Directory_buffer.is_dirty (directory t));
    let t = Session.save_current t in
    assert (exists (child (child dst "tree") "pending"));
    let t = Session.activate t id |> Or_error.ok_exn |> Session.save_current in
    assert (String.equal (In_channel.read_all newpath) "Xpayload");
    Session.dispose t)
;;

let%test_unit "phase8 dirty destination and normalized collisions refuse before mutation" =
  fixture (fun root ->
    Core_unix.mkdir (child root "src"); Core_unix.mkdir (child root "dst");
    let src = child root "src" and dst = child root "dst" in write src "a" "AAA";
    let t = Session.show_directory (start src) dst |> Or_error.ok_exn in
    let t = keys t "ipending<Esc>" |> fun t -> Session.show_directory t src |> Or_error.ok_exn in
    let d = directory t in
    let t = Session.replace_active t (snapshot d (row d "a" "../dst/a")).controller |> Session.save_current in
    assert (exists (child src "a") && not (exists (child dst "a")));
    let d = load src in
    let raw = row d "a" "../dst/a" ^ "\n" ^ copy_row d "a" "../dst/./a" in
    assert ((Directory_apply.apply (snapshot d raw)).completed = 0);
    Session.dispose t)
;;

let%test_unit "phase8 no-overwrite and destination-parent replacement race blocks moves" =
  fixture (fun root ->
    Core_unix.mkdir (child root "src"); Core_unix.mkdir (child root "dst");
    let src = child root "src" and dst = child root "dst" in write src "a" "AAA";
    let d = load src in
    let d = snapshot d (row d "a" "../dst/a") in
    let result = Directory_apply.apply d ~before_mutation:(fun step ->
      if step = 2 then write dst "a" "occupant") in
    assert (result.completed = 1 && Option.is_some result.error);
    assert (String.equal (read dst "a") "occupant");
    Core_unix.unlink (child dst "a");
    let retry = Directory_apply.apply result.buffer ~before_mutation:(fun step ->
      if step = 1 then (Core_unix.rename ~src:dst ~dst:(child root "old-dst"); Core_unix.mkdir dst)) in
    assert (retry.completed = 0 && Option.is_some retry.error);
    assert (not (exists (child dst "a")));
    Controller.close retry.buffer.controller)
;;

let%test_unit "phase8 copy publication fault and concurrent occupant leave no private tree or replay" =
  List.iter [ `Failure; `Occupant ] ~f:(fun fault -> fixture (fun root ->
    write root "a" "AAA";
    let d = load root in
    let raw = String.concat ~sep:"\n" [row d "a" "a"; copy_row d "a" "first"; copy_row d "a" "second"] in
    let first = Directory_apply.apply (snapshot d raw) ~before_copy_publish:(fun path ->
      if String.equal (Filename.basename path) "second" then match fault with
      | `Failure -> failwith "injected publication fault"
      | `Occupant -> Out_channel.write_all path ~data:"unrelated") in
    assert (first.completed = 1 && Option.is_some first.error);
    assert (String.equal (read root "first") "AAA");
    assert (not (Array.exists (Stdlib.Sys.readdir root) ~f:(String.is_prefix ~prefix:".ches-copy-")));
    (match fault with `Failure -> () | `Occupant ->
      assert (String.equal (read root "second") "unrelated"); Core_unix.unlink (child root "second"));
    let retry = Directory_apply.apply first.buffer in
    assert (Option.is_none retry.error && retry.completed = 1);
    assert (String.equal (read root "second") "AAA");
    Controller.close retry.buffer.controller))
;;

let%test_unit "phase8 external deletion also blocks direct controller routine save" =
  fixture (fun root ->
    write root "a" "recoverable";
    let c = Controller.open_file ~cell_width:width (child root "a") |> Or_error.ok_exn in
    Core_unix.unlink (child root "a");
    let c, _, _ = Controller.dispatch c [ Editor Save ] in
    assert (Controller.is_missing c && not (exists (child root "a")));
    assert (String.equal (Text_buffer.to_string (Editor.text (Controller.editor c))) "recoverable");
    let c = Controller.recreate c |> Or_error.ok_exn in
    assert (String.equal (read root "a") "recoverable");
    Controller.close c)
;;

let%test_unit "phase8 cross-device move is rejected before staging while copy may cross devices" =
  fixture (fun root ->
    match Option.try_with (fun () -> Core_unix.mkdtemp "/dev/shm/ches-phase8-") with
    | None -> () (* Environment does not provide a second writable filesystem. *)
    | Some target -> Exn.protect ~finally:(fun () -> remove_fixture target) ~f:(fun () ->
      if (Core_unix.stat root).st_dev <> (Core_unix.stat target).st_dev then (
        write root "a" "AAA";
        let d = load root in
        let result = Directory_apply.apply (snapshot d (row d "a" (child target "a") ^ "\nfresh")) in
        assert (Option.is_some result.error && result.completed = 0);
        assert (String.equal (read root "a") "AAA" && not (exists (child root "fresh")));
        let result = Directory_apply.apply (snapshot d (row d "a" "a" ^ "\n" ^ copy_row d "a" (child target "copy"))) in
        assert (Option.is_none result.error && String.equal (read target "copy") "AAA");
        Controller.close result.buffer.controller)))
;;

let%test_unit "phase8 directory copy/move reject symlink aliases into source with zero operations" =
  fixture (fun root ->
    Core_unix.mkdir (child root "tree"); write (child root "tree") "file" "keep";
    Core_unix.symlink ~target:"tree" ~link_name:(child root "alias");
    let d = load root in
    List.iter [row d "tree" "alias/new" ^ "\n" ^ row d "alias" "alias";
      Text_buffer.to_string (Directory_identity.text d.baseline) ^ "\n" ^ copy_row d "tree" "alias/new"] ~f:(fun raw ->
      let result = Directory_apply.apply (snapshot d raw) in
      assert (result.completed = 0 && Option.is_some result.error));
    assert (String.equal (read (child root "tree") "file") "keep");
    assert (Array.length (Stdlib.Sys.readdir (child root "tree")) = 1);
    Controller.close d.controller)
;;

let%test_unit "phase8 partial deletion marks the live buffer missing before retrying other intent" =
  fixture (fun root ->
    write root "a" "recover";
    let t, id = Session.open_or_activate (start root) (child root "a") |> Or_error.ok_exn in
    let t = Session.show_directory t root |> Or_error.ok_exn in
    let d = directory t in
    let t = Session.replace_active t (snapshot d "fresh").controller in
    let t = Session.For_testing.save_directory t d.id ~before_mutation:(fun step -> if step = 2 then failwith "after delete") in
    assert (Controller.is_missing (Session.find t id |> Option.value_exn));
    assert (not (exists (child root "a")) && not (exists (child root "fresh")));
    assert (List.equal Directory_plan.equal_operation (Directory_buffer.plan (directory t) |> Or_error.ok_exn) [ Create_file "fresh" ]);
    let t = Session.save_current t in
    assert (exists (child root "fresh") && not (exists (child root "a")));
    let t = Session.activate t id |> Or_error.ok_exn |> Session.save_current in
    assert (not (exists (child root "a")));
    Session.dispose t)
;;

let%test_unit "exclusive create, directory create, cycles, symlink and successful undo boundary" =
  fixture (fun root ->
    write root "a" "AAA"; write root "b" "BBB"; write root "c" "CCC";
    Core_unix.symlink ~target:"a" ~link_name:(child root "link");
    let d = edit (load root) [ "a", "b"; "b", "c"; "c", "a"; "link", "alias" ] "new\nsub/\nlink" in
    let result = Directory_apply.apply d in
    assert (Option.is_none result.error && result.completed = 11);
    assert (String.equal (read root "a") "CCC" && String.equal (read root "b") "AAA" && String.equal (read root "c") "BBB");
    assert (String.equal (Core_unix.readlink (child root "alias")) "a");
    assert (String.equal (read root "new") "" && String.equal (read root "link") "");
    assert (Directory_buffer.is_directory (child root "sub"));
    assert (not (Directory_buffer.is_dirty result.buffer));
    assert (List.is_empty (Directory_buffer.plan result.buffer |> Or_error.ok_exn));
    let controller, _, _ = Controller.dispatch result.buffer.controller [ Editor Undo ] in
    assert (Text_buffer.equal (Editor.text (Controller.editor controller)) (Directory_identity.text result.buffer.baseline));
    assert (not (Array.exists (Stdlib.Sys.readdir root) ~f:(String.is_prefix ~prefix:".ches-stage-")));
    Controller.close controller)
;;

let%test_unit "preflight rejects replacements, changed contents, occupied and dangling destinations with zero mutations" =
  fixture (fun root ->
    write root "a" "original";
    let d = edit (load root) [ "a", "b" ] "new" in
    write root "b" "unrelated";
    let result = Directory_apply.apply d in
    assert (Option.is_some result.error && result.completed = 0);
    assert (String.equal (read root "a") "original" && String.equal (read root "b") "unrelated");
    Core_unix.unlink (child root "b");
    Core_unix.symlink ~target:"missing" ~link_name:(child root "b");
    assert ((Directory_apply.apply d).completed = 0);
    Core_unix.unlink (child root "b");
    write root "replacement" "other inode";
    Core_unix.rename ~src:(child root "replacement") ~dst:(child root "a");
    assert ((Directory_apply.apply d).completed = 0);
    let d = edit (load root) [ "a", "b" ] "new" in
    write root "a" "externally changed size";
    assert ((Directory_apply.apply d).completed = 0);
    assert (not (exists (child root "new")));
    Controller.close d.controller)
;;

let%test_unit "faults at every stage of a swap reconcile actual backing paths and retry only unresolved work" =
  List.iter [ 1; 2; 3; 4; 5; 6 ] ~f:(fun fail_at ->
    fixture (fun root ->
      write root "a" "AAA"; write root "b" "BBB";
      let d = edit (load root) [ "a", "b"; "b", "a" ] "new\nsub/" in
      let result = Directory_apply.apply d ~before_mutation:(fun step ->
        if step = fail_at then failwith "injected failure") in
      assert (Option.is_some result.error && result.completed = fail_at - 1);
      assert (Directory_buffer.is_dirty result.buffer);
      List.iter result.buffer.entries ~f:(fun entry ->
        if entry.id = 1 then assert (String.equal (read root entry.name) "AAA")
        else if entry.id = 2 then assert (String.equal (read root entry.name) "BBB"));
      let retry = Directory_apply.apply result.buffer in
      assert (Option.is_none retry.error && not (Directory_buffer.is_dirty retry.buffer));
      assert (String.equal (read root "a") "BBB" && String.equal (read root "b") "AAA");
      assert (List.length retry.buffer.entries = 4);
      assert (not (Array.exists (Stdlib.Sys.readdir root) ~f:(String.is_prefix ~prefix:".ches-stage-")));
      if fail_at = 6 then (
        assert (retry.completed = 1);
        assert (List.equal Directory_plan.equal_operation retry.applied [ Create_directory "sub" ]));
      Controller.close retry.buffer.controller))
;;

let%test_unit "destination races never overwrite and replaced staged sources refuse retry" =
  fixture (fun root ->
    write root "a" "AAA";
    let d = edit (load root) [ "a", "b" ] "" in
    let result = Directory_apply.apply d ~before_mutation:(fun step -> if step = 2 then write root "b" "racer") in
    assert (result.completed = 1 && Option.is_some result.error);
    assert (String.equal (read root "b") "racer");
    let backing = (List.hd_exn result.buffer.entries).name in
    assert (String.is_prefix backing ~prefix:".ches-stage-");
    assert (String.equal (read root backing) "AAA");
    assert ((Directory_apply.apply result.buffer).completed = 0);
    Core_unix.unlink (child root "b");
    write root "replacement" "replacement";
    Core_unix.rename ~src:(child root "replacement") ~dst:(child root backing);
    assert ((Directory_apply.apply result.buffer).completed = 0);
    assert (String.equal (read root backing) "replacement");
    Controller.close result.buffer.controller)
;;

let%test_unit "create collision injected immediately before IO remains untouched and earlier creation is not replayed" =
  fixture (fun root ->
    let d = edit (load root) [] "a\nb/" in
    let result = Directory_apply.apply d ~before_mutation:(fun step -> if step = 2 then write root "b" "racer") in
    assert (result.completed = 1 && Option.is_some result.error);
    assert (String.equal (read root "b") "racer");
    write root "a" "saved after partial create";
    Core_unix.unlink (child root "b");
    let retry = Directory_apply.apply result.buffer in
    assert (Option.is_none retry.error && retry.completed = 1);
    assert (String.equal (read root "a") "saved after partial create");
    assert (Directory_buffer.is_directory (child root "b"));
    Controller.close retry.buffer.controller)
;;

let%test_unit "session dirty files descendants caches tabs language and resource indexes follow rename" =
  fixture (fun root ->
    write root "a.txt" "original";
    Core_unix.mkdir (child root "dir");
    write (child root "dir") "nested.ml" "let x = 1\n";
    let t = start root in
    let root_id = (directory t).id in
    let t, aid = Session.open_or_activate t (child root "a.txt") |> Or_error.ok_exn in
    let t = keys t "iDIRTY<Esc>" in
    let before = Option.value_exn (Session.find t aid) in
    let t, nid = Session.open_or_activate t (child (child root "dir") "nested.ml") |> Or_error.ok_exn in
    let t = keys t "iNESTED<Esc>" in
    let t = Session.show_directory t (child root "dir") |> Or_error.ok_exn in
    let cache_id = (directory t).id in
    let t = keys t "ochild<Esc>" in
    let cached_text = Editor.text (Controller.editor (directory t).controller) in
    let t = Session.show_directory t root |> Or_error.ok_exn in
    let t = edit_session t [ "a.txt", "a.ml"; "dir", "moved" ] "fresh" |> Session.save_current in
    assert (Buffer_id.equal (directory t).id root_id && not (Directory_buffer.is_dirty (directory t)));
    let after = Option.value_exn (Session.find t aid) in
    assert (Editor.revision (Controller.editor before) = Editor.revision (Controller.editor after));
    assert (Text_buffer.equal (Editor.text (Controller.editor before)) (Editor.text (Controller.editor after)));
    assert (Editor.is_dirty (Controller.editor after));
    assert (Option.equal String.equal (Controller.display_path after) (Some (child root "a.ml")));
    let key, _ = Controller.highlights after in
    assert (Ches_highlight.Language.equal (Ches_highlight.Snapshot.Key.language key) Ocaml);
    assert (Option.is_none (Session.find_resource t (child root "a.txt")));
    assert (Buffer_id.equal (fst (Session.find_resource t (child root "a.ml") |> Option.value_exn)) aid);
    let t = Session.show_directory t (child root "moved") |> Or_error.ok_exn in
    assert (Buffer_id.equal (directory t).id cache_id && Directory_buffer.is_dirty (directory t));
    assert (Text_buffer.equal cached_text (Editor.text (Controller.editor (directory t).controller)));
    assert (Option.is_none (Session.find_resource_buffer t (child root "dir")));
    let t, results = Session.save_all t in
    assert (List.length results = 3 && List.for_all results ~f:snd);
    assert (String.equal (read root "a.ml") "DIRTYoriginal");
    assert (String.is_prefix (read (child root "moved") "nested.ml") ~prefix:"NESTED");
    assert (exists (child (child root "moved") "child"));
    let t = Session.activate t nid |> Or_error.ok_exn |> fun t -> keys t "u" in
    assert (String.equal (Text_buffer.to_string (Editor.text (Controller.editor (Session.find t nid |> Option.value_exn)))) "let x = 1\n");
    Session.dispose t)
;;

let%test_unit "session refuses resource-index collision before filesystem mutation" =
  fixture (fun root ->
    write root "a" "AAA";
    let t = start root in
    let t, _ = Session.open_or_activate t (child root "missing") |> Or_error.ok_exn in
    let t = Session.show_directory t root |> Or_error.ok_exn in
    let t = edit_session t [ "a", "missing" ] "" |> Session.save_current in
    assert (Directory_buffer.is_dirty (directory t));
    assert (String.equal (read root "a") "AAA" && not (exists (child root "missing")));
    Session.dispose t)
;;

let%test_unit "partial session apply points dirty open files at actual staged paths and retry preserves history" =
  fixture (fun root ->
    write root "a" "AAA"; write root "b" "BBB";
    let t = start root in
    let root_id = (directory t).id in
    let t, aid = Session.open_or_activate t (child root "a") |> Or_error.ok_exn in
    let t = keys t "iDIRTY<Esc>" in
    let generation = Session.source_generation t aid |> Option.value_exn in
    let t, bid = Session.open_or_activate t (child root "b") |> Or_error.ok_exn in
    let t = keys t "iBDIRTY<Esc>" in
    let t = Session.show_directory t root |> Or_error.ok_exn in
    let t = edit_session t [ "a", "b"; "b", "a" ] "new" in
    let t = Session.For_testing.save_directory t root_id ~before_mutation:(fun step ->
      if step = 4 then failwith "injected final-placement failure") in
    assert (Directory_buffer.is_dirty (directory t));
    let path id = Editor.path (Controller.editor (Session.find t id |> Option.value_exn)) |> Option.value_exn in
    assert (String.equal (path aid) (child root "b"));
    assert (String.is_prefix (Filename.basename (path bid)) ~prefix:".ches-stage-");
    assert (String.equal (In_channel.read_all (path aid)) "AAA");
    assert ((Session.source_generation t aid |> Option.value_exn) <> generation);
    let staged = path bid in
    let t = Session.activate t bid |> Or_error.ok_exn |> Session.save_current in
    assert (String.equal (In_channel.read_all staged) "BDIRTYBBB");
    let t = Session.show_directory t root |> Or_error.ok_exn in
    let t = Session.save_current t in
    assert (not (Directory_buffer.is_dirty (directory t)));
    assert (String.equal (Editor.path (Controller.editor (Session.find t bid |> Option.value_exn)) |> Option.value_exn) (child root "a"));
    assert (String.equal (read root "a") "BDIRTYBBB");
    let t = Session.activate t aid |> Or_error.ok_exn |> Session.save_current in
    assert (String.equal (read root "b") "DIRTYAAA");
    let t = keys t "u" in
    assert (String.equal (Text_buffer.to_string (Editor.text (Controller.editor (Session.find t aid |> Option.value_exn)))) "AAA");
    Session.dispose t)
;;

let%test_unit "parent replacement and invalid plans cannot authorize mutation" =
  fixture (fun root ->
    let parent = child root "parent" in
    Core_unix.mkdir parent; write parent "a" "AAA";
    let d = edit (load parent) [ "a", "b" ] "" in
    Core_unix.rename ~src:parent ~dst:(child root "old");
    Core_unix.mkdir parent; write parent "a" "unrelated";
    let result = Directory_apply.apply d in
    assert (result.completed = 0 && Option.is_some result.error);
    assert (String.equal (read parent "a") "unrelated");
    let d = edit (load parent) [] "a" in
    assert ((Directory_apply.apply d).completed = 0);
    Controller.close d.controller)
;;

let%test_unit "staging skips occupied and session-reserved paths without overwriting either" =
  fixture (fun root ->
    write root "a" "AAA";
    let result = Directory_apply.apply (edit (load root) [ "a", "b" ] "")
      ~before_mutation:(fun step -> if step = 2 then failwith "stop after staging") in
    let staged = (List.hd_exn result.buffer.entries).name in
    let serial = String.rsplit2 staged ~on:'-' |> Option.value_exn |> snd |> Int.of_string in
    let name n = sprintf ".ches-stage-%d-%d" (Pid.to_int (Core_unix.getpid ())) n in
    let reserved = child root (name (serial + 1)) in
    write root (name (serial + 2)) "unrelated staging occupant";
    let retry = Directory_apply.apply result.buffer ~reserved_paths:[ reserved ]
      ~before_mutation:(fun step -> if step = 2 then failwith "stop again") in
    assert (retry.completed = 1 && Option.is_some retry.error);
    assert (String.equal (List.hd_exn retry.buffer.entries).name (name (serial + 3)));
    assert (not (exists reserved));
    assert (String.equal (read root (name (serial + 2))) "unrelated staging occupant");
    let final = Directory_apply.apply retry.buffer in
    assert (Option.is_none final.error && String.equal (read root "b") "AAA");
    Controller.close final.buffer.controller)
;;

let%test_unit "directory swaps reindex both dirty descendant files and dirty cached directories simultaneously" =
  fixture (fun root ->
    List.iter [ "a"; "b" ] ~f:(fun name -> Core_unix.mkdir (child root name); write (child root name) "file" name);
    let t = start root in
    let t, aid = Session.open_or_activate t (child (child root "a") "file") |> Or_error.ok_exn in
    let t = keys t "iA<Esc>" in
    let t, bid = Session.open_or_activate t (child (child root "b") "file") |> Or_error.ok_exn in
    let t = keys t "iB<Esc>" in
    let t = Session.show_directory t (child root "a") |> Or_error.ok_exn |> fun t -> keys t "ofreshA<Esc>" in
    let adir = (directory t).id in
    let t = Session.show_directory t (child root "b") |> Or_error.ok_exn |> fun t -> keys t "ofreshB<Esc>" in
    let bdir = (directory t).id in
    let t = Session.show_directory t root |> Or_error.ok_exn in
    let t = edit_session t [ "a", "b"; "b", "a" ] "" |> Session.save_current in
    let resource path = Session.find_resource t path |> Option.value_exn |> fst in
    assert (Buffer_id.equal (resource (child (child root "b") "file")) aid);
    assert (Buffer_id.equal (resource (child (child root "a") "file")) bid);
    let t = Session.show_directory t (child root "b") |> Or_error.ok_exn in
    assert (Buffer_id.equal (directory t).id adir && Directory_buffer.is_dirty (directory t));
    let t = Session.show_directory t (child root "a") |> Or_error.ok_exn in
    assert (Buffer_id.equal (directory t).id bdir && Directory_buffer.is_dirty (directory t));
    let t, outcomes = Session.save_all t in
    assert (List.length outcomes = 4 && List.for_all outcomes ~f:snd);
    assert (String.equal (read (child root "a") "file") "Bb" && String.equal (read (child root "b") "file") "Aa");
    assert (exists (child (child root "b") "freshA") && exists (child (child root "a") "freshB"));
    Session.dispose t)
;;

let%test_unit "save-all accepts its own earlier file write and queued saves follow reassociated resources" =
  fixture (fun root ->
    write root "a" "original";
    let t = Session.create ~cell_width:width (Controller.open_file ~cell_width:width (child root "a") |> Or_error.ok_exn) in
    let aid = Session.active_id t |> Option.value_exn in
    let t = Session.show_directory t root |> Or_error.ok_exn in
    let t = edit_session t [ "a", "b" ] "" in
    let t = Session.activate t aid |> Or_error.ok_exn |> fun t -> keys t "iEDIT<Esc>" in
    let t, outcomes = Session.save_all t in
    assert (List.length outcomes = 2 && List.for_all outcomes ~f:snd);
    assert (String.equal (read root "b") "EDIToriginal" && not (exists (child root "a")));
    let t, saves = Session.take_saved t in
    assert (List.length saves = 1 && String.equal (List.hd_exn saves).path (child root "b"));
    Session.dispose t)
;;

let%test_unit "the rename syscall itself rejects an occupant introduced after an absence check" =
  fixture (fun root ->
    write root "source" "source content";
    let source = child root "source" and destination = child root "destination" in
    assert (not (exists destination));
    write root "destination" "racing occupant";
    assert (Result.is_error (Or_error.try_with (fun () -> Directory_apply.For_testing.rename_noreplace source destination)));
    assert (String.equal (read root "source") "source content");
    assert (String.equal (read root "destination") "racing occupant");
    Core_unix.unlink destination;
    Core_unix.symlink ~target:"missing" ~link_name:destination;
    assert (Result.is_error (Or_error.try_with (fun () -> Directory_apply.For_testing.rename_noreplace source destination)));
    assert (String.equal (Core_unix.readlink destination) "missing");
    assert (String.equal (read root "source") "source content"))
;;
