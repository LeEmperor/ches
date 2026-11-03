open! Core
open Ches_core
open Ches_screen
open Test_language_navigation

let text t = Text_buffer.to_string (Editor.text (editor t))
let message t = (Option.value_exn (Ui_state.message t) : Ui_state.Message.t).text
let list : Q.instance_list =
  { module_name = "fifo"
  ; encoding = Utf16
  ; module_range = { start = { line = 0; character = 0 }; stop = { line = 2; character = 9 } }
  ; active = Some "top.narrow_fifo"
  ; instances = [ { hier_path = "top.narrow_fifo"; target = None }
                ; { hier_path = "top.wide_fifo"; target = None } ] }
let initial () = create "/tmp/instance-context.sv" "module fifo;\n  wire x;\nendmodule\nmodule other;\nendmodule"
let picker t =
  let t, query, _ = request t " ccSelect active instance<CR>" in
  reply t query (Instance_list list)
let choose t path =
  let t = picker t |> fun t -> press t path |> fun t -> press t "<CR>" in
  let t, requests = Ui_state.take_source_requests t in
  let query = List.find_map_exn requests ~f:(function
    | Ches_error.Source_request.Query ({ kind = Activate_instance _; _ } as q) -> Some q
    | _ -> None) in
  t, query
let activated (q : Q.request) = match q.kind with
  | Activate_instance context -> Q.Instance_activated context
  | _ -> assert false
let context_changed ?(revision = 1) ?module_name ?hier_path t =
  run t [ Source (Instance_context_changed { source = "fake"; revision; module_name; hier_path }) ]

let%test_unit "instance module bounds use only the explicitly negotiated Unicode encoding" =
  List.iter [Q.Utf8, "2l", 6; Utf16, "5l", 9; Utf32, "6l", 10]
    ~f:(fun (encoding, motion, start) ->
      let t = create "/tmp/instance-encoding.sv" "é😀abcdefghij" |> fun t -> press t motion in
      assert (Editor.cursor (editor t) = start);
      let t, query, _ = request t " ccSelect active instance<CR>" in
      let inventory = { list with encoding;
        module_range = { start = { line = 0; character = 6 }; stop = { line = 0; character = 10 } } } in
      let t = reply t query (Instance_list inventory) |> fun t -> press t "narrow<CR>" in
      let t, requests = Ui_state.take_source_requests t in
      let activation = List.find_map_exn requests ~f:(function
        | Ches_error.Source_request.Query ({ kind = Activate_instance _; _ } as q) -> Some q
        | _ -> None) in
      let t = reply t activation (activated activation) in
      assert (Option.is_some (Ui_state.active_instance_label t));
      let inside = press t "3l" in
      assert (Editor.cursor (editor inside) = start + 3);
      assert (Option.is_some (Ui_state.active_instance_label inside));
      let outside = press inside "l" in
      assert (Editor.cursor (editor outside) = start + 4);
      assert (Option.is_none (Ui_state.active_instance_label outside)))
;;

let%test_unit "references always open a searchable titled picker, including one dirty destination; acceptance records history" =
  with_files (fun _ a b ->
    let dirty, _ = Ui_state.open_file (create a "origin text") ~width ~height b |> Or_error.ok_exn in
    let dirty = press dirty "i界é<Esc>" in
    let origin, _ = Ui_state.open_file dirty ~width ~height a |> Or_error.ok_exn in
    List.iter [ [target b 2]; [target b 2; target a 0] ] ~f:(fun targets ->
      let pending, query, _ = request origin "gr" in
      let opened = reply pending query (Locations targets) in
      assert (Option.is_some (Ui_state.destinations opened));
      assert (String.equal (Option.value_exn (Editor.path (editor opened))) a);
      assert (String.is_substring (Frame.to_string (Frame.render opened ~width ~height)) ~substring:"Find references");
      let searched = press opened (Filename.basename b) in
      assert (Option.is_some (Destination_picker_tile.selected (Option.value_exn (Ui_state.destinations searched))));
      let jumped = press searched "<CR>" in
      assert (String.equal (Option.value_exn (Editor.path (editor jumped))) b);
      assert (String.is_prefix (text jumped) ~prefix:"界é");
      assert (Editor.cursor (editor jumped) = String.length "界é");
      let back = press jumped "<C-o>" in
      assert (String.equal (Option.value_exn (Editor.path (editor back))) a));
    let pending, query, _ = request origin "gr" in
    let empty = reply pending query (Locations []) in
    assert (Option.is_none (Ui_state.destinations empty));
    assert (String.equal (message empty) "No references found"))
;;

let%test_unit "instance acceptance queues a fresh activation token and changes neither text nor cursor nor undo" =
  List.iter [ "narrow"; "wide" ] ~f:(fun path ->
    let initial = initial () in
    let before = text initial in
    let t, query = choose initial path in
    assert (Option.is_none (Ui_state.instances t));
    assert (Option.is_none (Ui_state.active_instance_label t));
    assert (String.equal (text t) before);
    assert (Editor.cursor (editor t) = 0);
    assert (not (Editor.is_dirty (editor t)));
    let changed = context_changed ~module_name:"fifo" ~hier_path:("top." ^ path ^ "_fifo") t in
    let selected = reply changed query (activated query) in
    let expected = "Instance: top." ^ path ^ "_fifo" in
    assert (Option.equal String.equal (Ui_state.active_instance_label selected) (Some expected));
    assert (String.equal (text selected) before);
    assert (String.equal (message selected) expected);
    let hovering, hover_query, _ = request selected "K" in
    let hovering = reply hovering hover_query (Hover_result (Some hover)) in
    assert (String.is_substring (Frame.to_string (Frame.render hovering ~width ~height)) ~substring:expected);
    let changed = context_changed ~revision:2 hovering in
    assert (Option.is_none (Ui_state.hover changed));
    assert (Option.is_none (Ui_state.active_instance_label changed));
    assert (not (String.is_substring (Frame.to_string (Frame.render changed ~width ~height)) ~substring:expected));
    let outside = press selected "3j" in
    assert (Option.is_none (Ui_state.active_instance_label outside));
    assert (Option.is_none (Ui_state.active_instance_label (press outside "gg")));
    let stopped = run selected [ Source (Stopped { source = "fake"; root = "/tmp"; reason = "stopped" }) ] in
    assert (Option.is_none (Ui_state.active_instance_label stopped));
    assert (Option.is_none (Ui_state.hover stopped)))
;;

let%test_unit "stale activation acknowledgement invalidates old hover but never claims selected context" =
  let t, activation = choose (initial ()) "wide" in
  let moved = press t "l" in
  let hovering, query, _ = request moved "K" in
  let hovering = reply hovering query (Hover_result (Some hover)) in
  assert (Option.is_some (Ui_state.hover hovering));
  let late = reply hovering activation (activated activation) in
  assert (Option.is_none (Ui_state.hover late));
  assert (Option.is_none (Ui_state.active_instance_label late));
  let wrong_generation = { activation with token = { activation.token with generation = activation.token.generation + 1 } } in
  assert (Option.is_none (Ui_state.active_instance_label (reply t wrong_generation (activated activation))))
;;

let%test_unit "unsolicited context invalidation closes discovery and references across documents" =
  let opened = picker (initial ()) in
  assert (Option.is_some (Ui_state.instances opened));
  assert (Option.is_none (Ui_state.instances (context_changed opened)));
  let pending, query, _ = request (initial ()) "gr" in
  let opened = reply pending query (Locations [target "/tmp/other.sv" 0]) in
  assert (Option.is_some (Ui_state.destinations opened));
  assert (Option.is_none (Ui_state.destinations (context_changed opened)));
  let invalidated = context_changed pending in
  assert (Option.is_none (Ui_state.destinations (reply invalidated query (Locations [target "/tmp/other.sv" 0]))))
;;

let%test_unit "unsupported selectors and instantiation give source notice; unattached source queues nothing" =
  List.iter [ " ccSelect active instance<CR>"; " ccGo to instantiation<CR>"; "gr" ] ~f:(fun keys ->
    let t, query, _ = request (initial ()) keys in
    let failed = reply t query (Failed "Unsupported by this language server") in
    assert (String.equal (message failed) "Unsupported by this language server");
    assert (Option.is_none (Ui_state.instances failed));
    assert (Option.is_none (Ui_state.destinations failed));
    let unattached = Ui_state.create (Ui_state.controller (initial ())) |> fun t -> press t keys in
    let _, requests = Ui_state.take_source_requests unattached in
    assert (List.is_empty requests);
    assert (String.equal (message unattached) "Language source unavailable"));
  let pending, query, _ = request (initial ()) " ccGo to instantiation<CR>" in
  assert (String.is_substring (message (reply pending query (Locations []))) ~substring:"No instantiation location")
;;

let%test_unit "instantiation uses validated destination and jump history" =
  with_files (fun _ a b ->
    let origin = create a "origin text" in
    let pending, query, _ = request origin " ccGo to instantiation<CR>" in
    let invalid = reply pending query (Locations [target b 999]) in
    assert (String.equal (Option.value_exn (Editor.path (editor invalid))) a);
    let jumped = reply pending query (Locations [target b 1]) in
    assert (String.equal (Option.value_exn (Editor.path (editor jumped))) b);
    assert (Editor.cursor (editor jumped) = 1);
    let back = press jumped "<C-o>" in
    assert (String.equal (Option.value_exn (Editor.path (editor back))) a))
;;

let%test_unit "gr in Insert is text, and directory navigation never queues references" =
  let inserted = press (initial ()) "igr<Esc>" in
  assert (String.is_prefix (text inserted) ~prefix:"grmodule");
  let _, requests = Ui_state.take_source_requests inserted in
  assert (not (List.exists requests ~f:(function Ches_error.Source_request.Query _ -> true | _ -> false)));
  with_files (fun root a _ ->
    let directory = Ui_state.show_directory (create a "origin text") ~width ~height root |> Or_error.ok_exn in
    let directory = press directory "gr" in
    let _, requests = Ui_state.take_source_requests directory in
    assert (not (List.exists requests ~f:(function Ches_error.Source_request.Query _ -> true | _ -> false))))
;;

let%test_unit "switching document before activation acknowledgement drops the context claim" =
  with_files (fun _ a b ->
    let pending, query = choose (create a "module fifo;\n  wire x;\nendmodule") "wide" in
    let switched, _ = Ui_state.open_file pending ~width ~height b |> Or_error.ok_exn in
    let acknowledged = reply switched query (activated query) in
    assert (Option.is_none (Ui_state.active_instance_label acknowledged));
    assert (String.equal (Option.value_exn (Editor.path (editor acknowledged))) b))
;;

let%test_unit "a different confirmed context cancels activation acknowledgement continuation" =
  let pending, query = choose (initial ()) "wide" in
  List.iter [ context_changed ~module_name:"fifo" ~hier_path:"top.narrow_fifo" pending ] ~f:(fun changed ->
    let acknowledged = reply changed query (activated query) in
    assert (Option.is_none (Ui_state.active_instance_label acknowledged)))
;;

let%test_unit "activation send and refresh unknown events preserve acknowledgement but no speculative label" =
  let pending, query = choose (initial ()) "wide" in
  let changed = context_changed pending |> context_changed ~revision:2 in
  assert (Option.is_none (Ui_state.active_instance_label changed));
  let changed = context_changed ~revision:3 ~hier_path:"top.wide_fifo" changed in
  assert (Option.is_none (Ui_state.active_instance_label changed));
  let changed = context_changed ~revision:4 ~module_name:"fifo" ~hier_path:"top.wide_fifo" changed in
  let acknowledged = reply changed query (activated query) in
  assert (Option.equal String.equal (Ui_state.active_instance_label acknowledged) (Some "Instance: top.wide_fifo"))
;;

let%test_unit "unrelated pool context and lifecycle events preserve pending and visible references" =
  let initial = initial () in
  let server source resources : Ches_error.Source_event.Server.t =
    { source; resources; program = "fake"; args = []; root = "/tmp"; status = Running } in
  let servers = [server "fake" ["/tmp/instance-context.sv"]; server "other" ["/tmp/other.ml"]] in
  let initial = run initial [Source (Servers servers)] in
  let pending, query, _ = request initial "gr" in
  let events = [Ches_error.Source_event.Instance_context_changed
      {source = "other"; revision = 1; module_name = None; hier_path = None};
    Stopped {source = "other"; root = "/tmp"; reason = "exit"};
    Started {source = "other"; root = "/tmp"}] in
  List.iter events ~f:(fun event ->
    let opened = reply (run pending [Source event]) query (Locations [target "/tmp/other.sv" 0]) in
    assert (Option.is_some (Ui_state.destinations opened));
    assert (Option.is_some (Ui_state.destinations (run opened [Source event]))));
  let invalidated = context_changed pending in
  assert (Option.is_none (Ui_state.destinations (reply invalidated query (Locations [target "/tmp/other.sv" 0]))))
;;

let%test_unit "references reject destinations changed after discovery without altering dirty origin or history" =
  with_files (fun _ a b ->
    let origin = press (create a "origin text") "iunsaved <Esc>" in
    let before = text origin in
    let pending, query, _ = request origin "gr" in
    let picker = reply pending query (Locations [target b 0]) in
    Out_channel.write_all b ~data:"changed disk content";
    let rejected = press picker "<CR>" in
    assert (String.equal (Option.value_exn (Editor.path (editor rejected))) a);
    assert (String.equal (text rejected) before);
    assert (String.is_substring (message rejected) ~substring:"Destination changed");
    let back = press rejected "<C-o>" in
    assert (String.equal (text back) before);
    assert (String.equal (message back) "No further jump history"))
;;
