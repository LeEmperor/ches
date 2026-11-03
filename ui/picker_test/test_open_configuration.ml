open! Core
open! Async
open Bonsai_test
open Bonsai_term
module Expect_test_config = Async.Expect_test_config

let make_controller () = Ches_app.Controller.create (Ches_core.Editor.create
  ~cell_width:Ches_screen.Cell_map.width
  (Ches_core.Text_buffer.of_string "ORIGINAL DOCUMENT"
   |> Result.map_error ~f:Ches_core.Text_buffer.Invalid_text.to_string_hum
   |> Result.ok_or_failwith))
;;

let key handle key =
  Bonsai_term_test.send_event handle (Key_press { key; mods = [] })
;;

let type_text handle text = String.iter text ~f:(fun c -> key handle (ASCII c))

let open_configuration handle =
  type_text handle " ccOpen configuration";
  key handle Enter
;;

let%expect_test "Open configuration opens loader-selected paths and reuses modified buffers without executing config" =
  let view handle =
    Handle.recompute_view handle;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    [%expect.output] in
  let root = Filename_unix.temp_dir "ches-open-configuration" "" in
  Monitor.protect (fun () ->
    (* Resolve through the real loader with a local environment, never mutating the
       process environment or consulting the user's configuration. *)
    let cases =
      [ [ "XDG_CONFIG_HOME", root; "HOME", "/unused" ], "ches/config.ml"
      ; [ "XDG_CONFIG_HOME", "relative"; "HOME", root ], ".config/ches/config.ml"
      ; [ "XDG_CONFIG_HOME", ""; "HOME", root ], ".config/ches/config.ml"
      ] in
    Core_unix.mkdir (Filename.concat root "ches");
    Core_unix.mkdir (Filename.concat root ".config");
    Core_unix.mkdir (Filename.concat root ".config/ches");
    let%bind () = Deferred.List.iter ~how:`Sequential cases ~f:(fun (environment, relative) ->
      let path = Ches_config_runtime.Loader.config_path
        ~getenv:(fun name -> List.Assoc.find environment name ~equal:String.equal)
        |> Option.value_exn in
      assert (String.equal path (Filename.concat root relative));
      let source = "failwith \"OPEN MUST NOT EXECUTE CONFIGURATION\"\n" in
      Out_channel.write_all path ~data:source;
      let calls = ref 0 in
      let configuration = Ches_ui.Configuration_host.create ~load:(fun () ->
        incr calls; return (Error "unexpected configuration execution")) () in
      let controller = make_controller () in
      let handle = Bonsai_term_test.create_handle
        ~initial_dimensions:{ width = 160; height = 30 }
        (Ches_ui.Editor_view.app ~configuration_path:(Ok path) ~configuration
          ~bare:true controller ~exit:(fun () -> Effect.Ignore)) in
      open_configuration handle;
      assert (String.is_substring (view handle) ~substring:"OPEN MUST NOT EXECUTE CONFIGURATION");
      type_text handle "gg0iUNSAVED "; key handle Escape;
      type_text handle " bp";
      assert (String.is_substring (view handle) ~substring:"ORIGINAL DOCUMENT");
      open_configuration handle;
      assert (String.is_substring (view handle) ~substring:"UNSAVED failwith");
      assert (String.equal (In_channel.read_all path) source);
      (* Only the original and the config buffer exist: next wraps to original. *)
      type_text handle " bn";
      assert (String.is_substring (view handle) ~substring:"ORIGINAL DOCUMENT");
      let%bind () = Scheduler.yield_until_no_jobs_remain () in
      assert (!calls = 0);
      Ches_ui.Configuration_host.stop configuration;
      Ches_app.Controller.close controller;
      Core_unix.unlink path;
      return ()) in
    ignore ([%expect.output] : string);
    print_endline "XDG/HOME loader paths, palette open, modified-buffer reuse and no execution passed";
    [%expect {| XDG/HOME loader paths, palette open, modified-buffer reuse and no execution passed |}];
    return ())
    ~finally:(fun () ->
      List.iter [ "ches/config.ml"; ".config/ches/config.ml" ] ~f:(fun relative ->
        let path = Filename.concat root relative in
        if Sys_unix.file_exists_exn path then Core_unix.unlink path);
      List.iter [ "ches"; ".config/ches"; ".config"; "" ] ~f:(fun path ->
        Core_unix.rmdir (Filename.concat root path));
      return ())
;;

let%expect_test "missing configuration stays unsaved and path errors are frontend notifications" =
  let view handle =
    Handle.recompute_view handle;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    [%expect.output] in
  let root = Filename_unix.temp_dir "ches-missing-configuration" "" in
  let path = Filename.concat root "config.ml" in
  Monitor.protect (fun () ->
    let controller = make_controller () in
    let handle = Bonsai_term_test.create_handle
      ~initial_dimensions:{ width = 160; height = 30 }
      (Ches_ui.Editor_view.app ~configuration_path:(Ok path) ~bare:true
        controller ~exit:(fun () -> Effect.Ignore)) in
    open_configuration handle;
    assert (not (String.is_substring (view handle) ~substring:"ORIGINAL DOCUMENT"));
    assert (not (Sys_unix.file_exists_exn path));
    type_text handle "iUNSAVED CONFIG"; key handle Escape;
    type_text handle " bp";
    assert (String.is_substring (view handle) ~substring:"ORIGINAL DOCUMENT");
    open_configuration handle;
    assert (String.is_substring (view handle) ~substring:"UNSAVED CONFIG");
    assert (not (Sys_unix.file_exists_exn path));
    Ches_app.Controller.close controller;
    let controller = make_controller () in
    let handle = Bonsai_term_test.create_handle
      ~initial_dimensions:{ width = 160; height = 30 }
      (Ches_ui.Editor_view.app
        ~configuration_path:(Error "Missing usable HOME/XDG configuration location")
        ~bare:true controller ~exit:(fun () -> Effect.Ignore)) in
    open_configuration handle;
    let output = view handle in
    assert (String.is_substring output ~substring:"Missing usable HOME/XDG");
    assert (String.is_substring output ~substring:"ORIGINAL DOCUMENT");
    assert (not (Sys_unix.file_exists_exn path));
    Ches_app.Controller.close controller;
    ignore ([%expect.output] : string);
    print_endline "missing file stays in memory, reopens edits, and resolution errors notify without changing document";
    [%expect {| missing file stays in memory, reopens edits, and resolution errors notify without changing document |}];
    return ())
    ~finally:(fun () -> Core_unix.rmdir root; return ())
;;

let%expect_test "configuration path is installed on both explicit picker hosts' initial state" =
  let view handle =
    Handle.recompute_view handle;
    Bonsai_term_test.print_view (Bonsai_term_test.last_view handle);
    [%expect.output] in
  let root = Filename_unix.temp_dir "ches-picker-configuration" "" in
  let path = Filename.concat root "config.ml" in
  Out_channel.write_all path ~data:"PICKER HOST CONFIGURATION\n";
  Monitor.protect (fun () ->
    Deferred.List.iter ~how:`Sequential [ `File; `Content ] ~f:(fun kind ->
      let controller = make_controller () in
      let initial_ui = Ches_screen.Ui_state.create ~bare:true controller
        |> fun ui -> Ches_screen.Ui_state.with_configuration_path ui
          (Error "stale picker host configuration path") in
      let file_runtime = Ches_file_picker_host.Runtime.create () in
      let content_runtime = Ches_content_picker_host.Runtime.create () in
      let file_picker, content_picker = match kind with
        | `File ->
          Some ({ initial_ui; runtime = file_runtime; consume = (fun _ -> ()) }
            : Ches_ui.Editor_view.File_picker_host.t), None
        | `Content ->
          None, Some ({ initial_ui; runtime = content_runtime; consume = (fun _ -> ()) }
            : Ches_ui.Editor_view.Content_picker_host.t) in
      let handle = Bonsai_term_test.create_handle
        ~initial_dimensions:{ width = 160; height = 30 }
        (Ches_ui.Editor_view.app ~configuration_path:(Ok path) ?file_picker ?content_picker
          controller ~exit:(fun () -> Effect.Ignore)) in
      open_configuration handle;
      let output = view handle in
      assert (String.is_substring output ~substring:"PICKER HOST CONFIGURATION");
      assert (not (String.is_substring output ~substring:"stale picker host"));
      Ches_file_picker_host.Runtime.cancel file_runtime;
      Ches_content_picker_host.Runtime.cancel content_runtime;
      let%bind () = Ches_file_picker_host.Runtime.finished file_runtime in
      let%map () = Ches_content_picker_host.Runtime.finished content_runtime in
      Ches_app.Controller.close controller)
    >>| fun () ->
    ignore ([%expect.output] : string);
    print_endline "file and content picker initial states receive the frontend configuration path";
    [%expect {| file and content picker initial states receive the frontend configuration path |}])
    ~finally:(fun () -> Core_unix.unlink path; Core_unix.rmdir root; return ())
;;
