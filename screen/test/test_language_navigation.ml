open! Core
open Ches_core
open Ches_app
open Ches_screen
module Q = Ches_error.Language_query

let width = 100
let height = 25
let run t inputs = Helpers.run ~width ~height t inputs
let press t keys = run t (Helpers.keys keys)
let editor t = Controller.editor (Ui_state.controller t)
let create path text =
  let text = Text_buffer.of_string text |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith in
  Ui_state.create ~source_attached:true ~tiles_visible:false
    (Controller.create (Editor.create ~path ~cell_width:Cell_map.width text))
let request t keys =
  let t = press t keys in
  let t, requests = Ui_state.take_source_requests t in
  let request = List.find_map_exn requests ~f:(function
    | Ches_error.Source_request.Query request -> Some request | _ -> None) in
  t, request, requests
let reply t (request : Q.request) result =
  run t [ Source (Query_result { token = request.token; cursor = request.cursor
    ; kind = request.kind; source = "fake"; result }) ]
let target path character : Q.target =
  let position = { Q.line = 0; character } in
  let range = { Q.start = position; stop = position } in
  { path; range; selection = range; encoding = Utf16 }
let hover : Q.hover =
  { contents = [ { kind = Markdown; value = String.concat ~sep:"\n"
      (List.init 80 ~f:(fun i -> sprintf "line %d documentation" i)) } ]; range = None }

let%test_unit "bare uppercase hover and declaration/definition keys and palette use ordered source queries" =
  List.iter [ "K", Q.Hover; "gd", Q.Declaration; "gD", Q.Definition;
      "gr", Q.References; " ccFind references<CR>", Q.References;
      " ccSelect active instance<CR>", Q.Instances;
      " ccGo to instantiation<CR>", Q.Instantiation;
      " ccHover<CR>", Q.Hover;
      " ccGo to declaration<CR>", Q.Declaration;
      " ccGo to definition<CR>", Q.Definition ] ~f:(fun (keys, kind) ->
    let _, query, requests = request (create "/tmp/navigation.ml" "abc") keys in
    assert (Q.equal_kind query.kind kind);
    assert (query.cursor = 0);
    assert (List.exists requests ~f:(function Document_changed _ -> true | _ -> false));
    assert (match List.last requests with Some (Query _) -> true | _ -> false));
  let _, requests = Ui_state.take_source_requests (press (create "/tmp/navigation.ml" "a\nb") "jk") in
  assert (not (List.exists requests ~f:(function Query _ -> true | _ -> false)))
;;

let%test_unit "hover scrolls, renders, closes, cancels and drops wrong cursor and superseded replies" =
  let t, query, _ = request (create "/tmp/navigation.ml" "abcdef") "K" in
  let wrong = run t [ Source (Query_result { token = query.token; cursor = 1
    ; kind = query.kind; source = "fake"; result = Hover_result (Some hover) }) ] in
  assert (Option.is_none (Ui_state.hover wrong));
  let opened = reply wrong query (Hover_result (Some hover)) in
  assert (Option.is_some (Ui_state.hover opened));
  assert (String.is_substring (Frame.to_string (Frame.render opened ~width ~height)) ~substring:"documentation");
  let scrolled = press opened "<C-d>" in
  assert (Hover_tile.top (Option.value_exn (Ui_state.hover scrolled)) > 0);
  let closed = press scrolled "q" in
  assert (Option.is_none (Ui_state.hover closed));
  assert (Editor.cursor (editor closed) = 0);
  let _, commands = Ui_state.take_source_requests closed in
  assert (List.exists commands ~f:(function Cancel_query token -> Ches_completion.Model.Token.equal token query.token | _ -> false));
  let moved = press t "l" |> fun t -> reply t query (Hover_result (Some hover)) in
  assert (Option.is_none (Ui_state.hover moved));
  let cancelled = press t "<Esc>" |> fun t -> reply t query (Hover_result (Some hover)) in
  assert (Option.is_none (Ui_state.hover cancelled));
  let second, newer, _ = request t "K" in
  assert (newer.token.request > query.token.request);
  assert (Option.is_none (Ui_state.hover (reply second query (Hover_result (Some hover)))));
  assert (Option.is_some (Ui_state.hover (reply second newer (Hover_result (Some hover)))))
;;

let with_files f =
  let root = Helpers.scratch_dir "ches-language-navigation-" in
  let a = Filename.concat root "origin.ml" and b = Filename.concat root "target.ml" in
  Out_channel.write_all a ~data:"origin text";
  Out_channel.write_all b ~data:"disk";
  Exn.protect ~finally:(fun () -> Core_unix.unlink a; Core_unix.unlink b; Core_unix.rmdir root)
    ~f:(fun () -> f root a b)
;;

let%test_unit "zero width Unicode destination uses retained dirty target; invalid ranges and missing paths never activate" =
  with_files (fun root a b ->
    let initial = create a "origin text" in
    let dirty, _ = Ui_state.open_file initial ~width ~height b |> Or_error.ok_exn in
    let dirty = press dirty "i界é<Esc>" in
    let initial, _ = Ui_state.open_file dirty ~width ~height a |> Or_error.ok_exn in
    let pending, query, _ = request initial "gd" in
    let jumped = reply pending query (Locations [target b 2]) in
    assert (String.equal (Option.value_exn (Editor.path (editor jumped))) b);
    assert (String.is_prefix (Text_buffer.to_string (Editor.text (editor jumped))) ~prefix:"界é");
    assert (Editor.cursor (editor jumped) = String.length "界é");
    List.iter [ target b 100; target (Filename.concat root "missing.ml") 0;
        { (target b 0) with range = { start = { line = 0; character = 2 }; stop = { line = 0; character = 1 } } } ]
      ~f:(fun target ->
        let failed = reply pending query (Locations [target]) in
        assert (String.equal (Option.value_exn (Editor.path (editor failed))) a));
    assert (not (Sys_unix.file_exists_exn (Filename.concat root "missing.ml"))))
;;

let%test_unit "multiple picker accepts exact selection; none and failure report notices" =
  with_files (fun _ a b ->
    let pending, query, _ = request (create a "origin text") "gD" in
    let picker = reply pending query (Locations [target b 0; target b 1]) in
    assert (Option.is_some (Ui_state.destinations picker));
    assert (String.equal (Option.value_exn (Editor.path (editor picker))) a);
    let unmatched = run picker (Helpers.paste "nonexistent symbol path") |> fun t -> press t "<CR>" in
    assert (Option.is_some (Ui_state.destinations unmatched));
    assert (Option.is_none (Destination_picker_tile.selected (Option.value_exn (Ui_state.destinations unmatched))));
    let jumped = press picker "<CR>" in
    assert (Option.is_none (Ui_state.destinations jumped));
    assert (String.equal (Option.value_exn (Editor.path (editor jumped))) b);
    assert (Option.is_none (Ui_state.destinations (press picker "<Esc>")));
    let no_results = reply pending query (Locations []) in
    assert (String.is_substring (Option.value_exn (Ui_state.message no_results)).text ~substring:"No destinations");
    let failed = reply pending query (Failed "fake unavailable") in
    assert (String.equal (Option.value_exn (Ui_state.message failed)).text "fake unavailable"))
;;

let%test_unit "picker refuses a retained target whose lifetime changed while choosing" =
  with_files (fun _ a b ->
    let initial = create a "origin text" in
    let retained, id = Ui_state.open_file initial ~width ~height b |> Or_error.ok_exn in
    let origin, _ = Ui_state.open_file retained ~width ~height a |> Or_error.ok_exn in
    let pending, query, _ = request origin "gd" in
    let picker = reply pending query (Locations [target b 0; target b 1]) in
    let closed, did_close = Ui_state.close_buffer picker ~width ~height id ~force:true in
    assert did_close;
    assert (Option.is_some (Ui_state.destinations closed));
    let rejected = press closed "<CR>" in
    assert (String.equal (Option.value_exn (Editor.path (editor rejected))) a);
    assert (String.is_substring (Option.value_exn (Ui_state.message rejected)).text ~substring:"Destination changed"))
;;

let%test_unit "history traverses with Tab alias only in Normal documents and new jumps truncate forward" =
  with_files (fun _ a b ->
    let pending, query, _ = request (create a "origin text") "gd" in
    let jumped = reply pending query (Locations [target b 1]) in
    let back = press jumped "<C-o>" in
    assert (String.equal (Option.value_exn (Editor.path (editor back))) a);
    let forward = press back "<Tab>" in
    assert (String.equal (Option.value_exn (Editor.path (editor forward))) b);
    let insert = press back "i<Tab>" in
    assert (String.equal (Option.value_exn (Editor.path (editor insert))) a);
    assert (Mode.equal (Editor.mode (editor insert)) Insert);
    let pending, query, _ = request back "gD" in
    let branch = reply pending query (Locations [target a 3]) in
    let stayed = press branch "<C-i>" in
    assert (String.equal (Option.value_exn (Editor.path (editor stayed))) a);
    assert (Editor.cursor (editor stayed) = 3))
;;

let%test_unit "close/reopen and picker origin changes invalidate query lifetime" =
  with_files (fun _ a b ->
    let pending, query, _ = request (create a "origin text") "gd" in
    let closed, did_close = Ui_state.close_current pending ~width ~height ~force:true in
    assert did_close;
    let reopened, _ = Ui_state.open_file closed ~width ~height a |> Or_error.ok_exn in
    let stale = reply reopened query (Locations [target b 0]) in
    assert (String.equal (Option.value_exn (Editor.path (editor stale))) a);
    let picker = reply pending query (Locations [target b 0; target b 1]) in
    let switched, _ = Ui_state.open_file picker ~width ~height b |> Or_error.ok_exn in
    assert (Option.is_none (Ui_state.destinations switched));
    let resized = Helpers.run ~width:10 ~height:2 picker [ Resize ] in
    assert (Option.is_none (Ui_state.destinations resized));
    let opened = reply pending query (Hover_result (Some hover)) in
    let replaced = Ui_state.open_line_picker opened ~width ~height in
    assert (Option.is_none (Ui_state.hover replaced));
    assert (Option.is_some (Ui_state.line_picker replaced)))
;;

let%test_unit "failed traversal preserves forward branch and Tab does not steal picker or terminal input" =
  with_files (fun _ a b ->
    let pending, query, _ = request (create a "origin text") "gd" in
    let jumped = reply pending query (Locations [target b 1]) in
    let back = press jumped "<C-o>" in
    let closed, did_close = Ui_state.close_buffer back ~width ~height
        (List.find_map_exn (Session.buffers (Ui_state.session back)) ~f:(fun (id, controller) ->
          if Option.equal String.equal (Editor.path (Controller.editor controller)) (Some b) then Some id else None))
        ~force:true in
    assert did_close;
    Core_unix.unlink b;
    Exn.protect ~finally:(fun () -> Out_channel.write_all b ~data:"disk") ~f:(fun () ->
      let failed = press closed "<C-i>" in
      assert (String.equal (Option.value_exn (Editor.path (editor failed))) a);
      Out_channel.write_all b ~data:"disk";
      let forward = press failed "<C-i>" in
      assert (String.equal (Option.value_exn (Editor.path (editor forward))) b));
    let picker = Ui_state.open_line_picker back ~width ~height in
    let picker = press picker "<Tab>" in
    assert (String.equal (Option.value_exn (Editor.path (editor picker))) a);
    let terminal = press back " /" in
    let terminal = run terminal [ Terminal_key Ches_terminal.Model.{ code = Tab; modifiers = no_modifiers } ] in
    assert (String.equal (Option.value_exn (Editor.path (editor terminal))) a))
;;

let%test_unit "source stop invalidates pending replies even within one event batch" =
  let pending, query, _ = request (create "/tmp/navigation.ml" "abc") "K" in
  let result = Ches_error.Source_event.Query_result
      { token = query.token; cursor = query.cursor; kind = query.kind
      ; source = "fake"; result = Hover_result (Some hover) } in
  let stopped = run pending
      [ Source (Stopped { source = "fake"; root = "/tmp"; reason = "exit" }); Source result ] in
  assert (Option.is_none (Ui_state.hover stopped));
  let opened = reply pending query (Hover_result (Some hover)) in
  let stopped = run opened [ Source (Unavailable { source = "fake"; root = "/tmp"; reason = "gone" }) ] in
  assert (Option.is_none (Ui_state.hover stopped))
;;

let%test_unit "unopened picker destinations changed externally are rejected without losing dirty origin" =
  with_files (fun _ a b ->
    let origin = press (create a "origin text") "iunsaved <Esc>" in
    let before = Text_buffer.to_string (Editor.text (editor origin)) in
    let pending, query, _ = request origin "gd" in
    let picker = reply pending query (Locations [target b 0; target b 1]) in
    Out_channel.write_all b ~data:"changed disk content";
    let rejected = press picker "<CR>" in
    assert (String.equal (Option.value_exn (Editor.path (editor rejected))) a);
    assert (String.equal (Text_buffer.to_string (Editor.text (editor rejected))) before);
    assert (String.is_substring (Option.value_exn (Ui_state.message rejected)).text ~substring:"Destination changed"))
;;

let%test_unit "line end destination normalizes cursor and history stores the normalized location" =
  with_files (fun _ a b ->
    Out_channel.write_all b ~data:"界é\n";
    let pending, query, _ = request (create a "origin text") "gd" in
    let jumped = reply pending query (Locations [target b 2]) in
    assert (Editor.cursor (editor jumped) = String.length "界");
    let back = press jumped "<C-o>ll" in
    assert (Editor.cursor (editor back) = 2);
    let forward = press back "<C-i>" in
    assert (Editor.cursor (editor forward) = String.length "界");
    let back = press forward "<C-o>" in
    assert (Editor.cursor (editor back) = 2))
;;

let%test_unit "navigation and history preserve exact combining-scalar byte positions" =
  with_files (fun _ a b ->
    Out_channel.write_all b ~data:"éx";
    let pending, query, _ = request (create a "origin text") "gd" in
    let jumped = reply pending query (Locations [target b 1]) in
    assert (Editor.cursor (editor jumped) = 1);
    let back = press jumped "<C-o>" in
    let forward = press back "<C-i>" in
    assert (Editor.cursor (editor forward) = 1))
;;

let%test_unit "same revision movement mode and focus changes invalidate replies permanently" =
  with_files (fun _ a b ->
    let retained, _ = Ui_state.open_file (create a "origin text") ~width ~height b |> Or_error.ok_exn in
    let origin, _ = Ui_state.open_file retained ~width ~height a |> Or_error.ok_exn in
    let pending, query, _ = request origin "gd" in
    List.iter ["lh"; "i<Esc>"; " cc<Esc>"; " /<Esc>"; " bn bp"] ~f:(fun keys ->
      let changed = press pending keys in
      assert (Editor.revision (editor changed) = query.token.revision);
      assert (Editor.cursor (editor changed) = query.cursor);
      let stale = reply changed query (Locations [target b 1]) in
      assert (String.equal (Option.value_exn (Editor.path (editor stale))) a);
      let target_controller = Session.find_resource (Ui_state.session stale) b |> Option.value_exn |> snd in
      assert (Editor.cursor (Controller.editor target_controller) = 0)))
;;

let%test_unit "failed exact destination validation retains dirty origin and dirty destination" =
  with_files (fun root a b ->
    let origin = press (create a "origin text") "iunsaved origin <Esc>" in
    let retained, _ = Ui_state.open_file origin ~width ~height b |> Or_error.ok_exn in
    let retained = press retained "i界target <Esc>" in
    let origin, _ = Ui_state.open_file retained ~width ~height a |> Or_error.ok_exn in
    let before = Text_buffer.to_string (Editor.text (editor origin)) in
    let target_before = Session.find_resource (Ui_state.session origin) b |> Option.value_exn |> snd |> Controller.editor in
    let pending, query, _ = request origin "gd" in
    let invalid_selection = { (target b 0) with selection = (target b 1).selection } in
    List.iter [target b 100; invalid_selection; target (Filename.concat root "missing.ml") 0]
      ~f:(fun target ->
        let failed = reply pending query (Locations [target]) in
        assert (String.equal (Option.value_exn (Editor.path (editor failed))) a);
        assert (String.equal before (Text_buffer.to_string (Editor.text (editor failed))));
        assert (Editor.is_dirty (editor failed));
        let target_after = Session.find_resource (Ui_state.session failed) b |> Option.value_exn |> snd |> Controller.editor in
        assert (String.equal (Text_buffer.to_string (Editor.text target_before))
                  (Text_buffer.to_string (Editor.text target_after)));
        assert (Editor.is_dirty target_after);
        assert (Editor.cursor target_before = Editor.cursor target_after)))
;;

let%test_unit "same file picker and hover closure return focus without moving or altering the document" =
  with_files (fun _ a _ ->
    let origin = press (create a "origin text") "iunsaved <Esc>" in
    let pending, query, _ = request origin "gd" in
    let picker = reply pending query (Locations [target a 0; target a 2]) in
    let jumped = press picker "<Tab><CR>" in
    assert (Editor.cursor (editor jumped) = 2);
    List.iter ["q"; "<Esc>"] ~f:(fun close ->
      let pending, query, _ = request origin "K" in
      let opened = reply pending query (Hover_result (Some hover)) in
      let closed = press opened close in
      assert (Ches_tile.View_id.equal (Ui_state.focused_view closed ~width ~height)
                (Ches_tile.View_id.of_string "document"));
      assert (Editor.cursor (editor closed) = Editor.cursor (editor origin));
      assert (String.equal (Text_buffer.to_string (Editor.text (editor closed)))
                (Text_buffer.to_string (Editor.text (editor origin))));
      assert (Editor.is_dirty (editor closed));
      assert (Option.is_none (Ui_state.hover closed))))
;;
