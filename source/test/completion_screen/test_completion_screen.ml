open! Core
open! Async
open Ches_source
module U = Ches_screen.Ui_state
module Model = Ches_completion.Model
module Editor = Ches_core.Editor
module Controller = Ches_app.Controller

let text ui = Ches_core.Text_buffer.to_string (Editor.text (Controller.editor (U.controller ui)))
let revision ui = Editor.revision (Controller.editor (U.controller ui))
let apply ui inputs = fst (U.apply_all ui ~width:60 ~height:12 inputs)
let key ui key = apply ui [Key key]
let chars ui s = String.fold s ~init:ui ~f:(fun ui c -> key ui (Ches_input.Key.Char (Uchar.of_char c)))

let flush source ui =
  let ui, requests = U.take_source_requests ui in
  List.iter requests ~f:(Source.send source);
  ui, requests
;;

let rec pump source ui ~until =
  if until ui then return ui else
  match%bind Clock_ns.with_timeout (Time_ns.Span.of_int_sec 3) (Source.next_batch source) with
  | `Timeout -> failwith "source/screen completion timeout"
  | `Result events -> pump source (apply ui (List.map events ~f:(fun event -> U.Input.Source event))) ~until
;;

let rec diagnostics source =
  let rec is_diagnostic = function
    | Ches_error.Source_event.Diagnostics _ -> true
    | Owned { event; _ } -> is_diagnostic event
    | _ -> false in
  match%bind Clock_ns.with_timeout (Time_ns.Span.of_int_sec 3) (Source.next_batch source) with
  | `Timeout -> failwith "source/screen initialize timeout"
  | `Result events -> if List.exists events ~f:is_diagnostic then return () else diagnostics source
;;

let with_root f =
  let root = Filename_unix.realpath (Filename_unix.temp_dir "ches-completion-screen" "") in
  Monitor.protect (fun () -> f root)
    ~finally:(fun () -> Process.run ~prog:"rm" ~args:["-rf"; root] () >>| ignore)
;;

let start root args =
  let config = { Lsp_client.Config.ocamllsp with source = "fake";
    prog = Filename.concat (Core_unix.getcwd ()) "../fake_lsp/fake_lsp.exe";
    args = "-next-completion" :: args } in
  let source = Lsp_client.start ~config ~cell_width:(fun _ -> 1) ~root () in
  let buffer = Ches_core.Text_buffer.of_string "\nSuffix" |> Result.ok |> Option.value_exn in
  let ui = U.create ~tiles_visible:false ~source_attached:true
    (Controller.create (Editor.create ~path:(Filename.concat root "a.ml") ~cell_width:(fun _ -> 1) buffer)) in
  let ui, _ = flush source ui in
  let%bind () = diagnostics source in
  let ui = chars ui "jifo" in
  let ui, requests = flush source ui in
  let query = List.find_map_exn requests ~f:(function Ches_error.Source_request.Complete query -> Some query | _ -> None) in
  let%map ui = pump source ui ~until:(fun ui -> Option.is_some (U.completion_info ui)) in
  source, ui, query
;;

let%expect_test "real wire resolve and screen acceptance agree before Tab, after Tab, and while acceptance is deferred" =
  let%bind () = Deferred.List.iter ["before"; "after"; "deferred"; "typed"; "expired"] ~how:`Sequential ~f:(fun scenario ->
    with_root (fun root ->
      let args = if String.equal scenario "before" then [] else ["-hold-resolve"] in
      let%bind source, ui, query = start root args in
      let ui, _ = flush source ui in
      let%bind ui = if String.equal scenario "before" then
        pump source ui ~until:(fun ui -> Option.exists (U.completion_info ui)
          ~f:(fun info -> Option.is_some info.additional))
        else return ui in
      let ui = key ui Tab in
      assert (String.equal (text ui) "\nformatted");
      let ui = if List.mem ["deferred"; "typed"; "expired"] scenario ~equal:String.equal then key ui Enter else ui in
      let ui = if String.equal scenario "typed" then chars ui "!" else ui in
      let ui, _ = flush source ui in
      (* Deliberately deliver no frontend tick: arrival itself must enforce the
         acceptance deadline even though the source request is still live. *)
      let%bind () = if String.equal scenario "expired" then
        Clock_ns.after (Time_ns.Span.of_ms 1100.) else return () in
      if not (String.equal scenario "before") then
        Source.send source (Document_saved { resource = query.token.resource; revision = revision ui });
      let%bind ui = match scenario with
        | "before" -> return (key ui Enter)
        | "after" ->
          let%map ui = pump source ui ~until:(fun ui -> Option.exists (U.completion_info ui)
            ~f:(fun info -> Option.is_some info.additional)) in
          key ui Enter
        | "deferred" -> pump source ui ~until:(fun ui -> String.is_prefix (text ui) ~prefix:"import\n")
        | "typed" ->
          let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
          apply ui (List.map (Source.poll source) ~f:(fun event -> U.Input.Source event))
        | "expired" ->
          let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
          let events = Source.poll source in
          assert (List.exists events ~f:(function
            | Completion_metadata { items; _ } -> List.exists items ~f:(fun info -> Option.is_some info.additional)
            | _ -> false));
          apply ui (List.map events ~f:(fun event -> U.Input.Source event))
        | _ -> assert false in
      let expected = match scenario with
        | "typed" -> "\nformatted!" | "expired" -> "\nformatted" | _ -> "import\n\nformatted" in
      assert (String.equal (text ui) expected);
      assert (not (U.toggle_key_pending ui));
      Source.stop source;
      return ())) in
  [%expect {| |}];
  return ()
;;

let%expect_test "raw-item expiry cancels held resolve and expired tokens cannot query the server again" =
  with_root (fun root ->
    let log = Filename.concat root "wire.log" in
    let%bind source, ui, query = start root ["-hold-resolve"; "-log"; log] in
    let _, _ = flush source ui in
    (* Exercise the real fixed lifetime: document changes/selection must not
       extend this timer or resurrect a raw item after expiry. *)
    let%bind () = Clock_ns.after (Time_ns.Span.of_ms 10100.) in
    Source.send source (Resolve_completion { token = query.token; candidate_id = "fake:0"; revision = query.token.revision });
    Source.send source (Document_saved { resource = query.token.resource; revision = query.token.revision });
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
    let events = Source.poll source in
    assert (not (List.exists events ~f:(function
      | Completion_metadata { items; _ } -> List.exists items ~f:(fun info -> Option.is_some info.additional)
      | _ -> false)));
    let%bind lines = Reader.file_lines log in
    assert (List.count lines ~f:(String.is_suffix ~suffix:"completionItem/resolve") = 1);
    assert (List.exists lines ~f:(String.is_suffix ~suffix:"$/cancelRequest"));
    Source.stop source;
    [%expect {| |}];
    return ())
;;
