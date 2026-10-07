(* A scripted language server for the client tests: it speaks the protocol over stdin and
   stdout like ocamllsp, but its "checks" are keywords.

   Each line of the open document containing ERROR, WARN, INFO, HINT, NOSEV (no
   severity), or MULTI (a multi-line message) gets one diagnostic at the keyword,
   versioned with the document. If an [other.ml] sits beside the document, its first
   line containing OTHER gets an unversioned warning there. A document containing
   CRASH makes the server exit 3 after a line on stderr.

   Flags: [-encoding utf-8|utf-16|none] picks the position encoding it reports (none:
   the protocol's default, UTF-16); [-fail-init] answers [initialize] with an error;
   [-exit-at-start] exits 2 at once; [-request-first] asks the client for configuration
   and a progress token after [initialized], and publishes nothing until both are
   answered. *)
open! Core
module Types = Lsp.Types

module Io =
  Lsp.Io.Make
    (struct
      type 'a t = 'a

      let return x = x
      let raise = raise

      module O = struct
        let ( let+ ) x f = f x
        let ( let* ) x f = f x
      end
    end)
    (struct
      type input = In_channel.t
      type output = Out_channel.t

      let read_line input = In_channel.input_line input

      let read_exactly input length =
        Option.try_with (fun () -> Stdlib.really_input_string input length)
      ;;

      let write output strings =
        List.iter strings ~f:(Out_channel.output_string output);
        Out_channel.flush output
      ;;
    end)

let encoding = ref "utf-16"
let fail_init = ref false
let request_first = ref false
let awaiting = ref 0
let latest : (Lsp.Uri.t * int * string) option ref = ref None

let send packet = Io.write Out_channel.stdout packet

(* [byte] counted in the encoding's units. *)
let units line byte =
  let prefix = String.prefix line byte in
  match !encoding with
  | "utf-8" -> byte
  | _ ->
    let rec count pos acc =
      if pos >= String.length prefix
      then acc
      else (
        let d = Stdlib.String.get_utf_8_uchar prefix pos in
        let u = Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar d) in
        count (pos + Stdlib.Uchar.utf_decode_length d) (acc + if u >= 0x10000 then 2 else 1))
    in
    count 0 0
;;

let diagnostic ?severity ~line ~character message =
  let position = Types.Position.create ~line ~character in
  Types.Diagnostic.create
    ?severity
    ~message:(`String message)
    ~range:(Types.Range.create ~start:position ~end_:position)
    ()
;;

let publish ?version uri diagnostics =
  send
    (Notification
       (Lsp.Server_notification.to_jsonrpc
          (PublishDiagnostics
             (Types.PublishDiagnosticsParams.create ~uri ?version ~diagnostics ()))))
;;

let keywords : (string * Types.DiagnosticSeverity.t option * string) list =
  [ "ERROR", Some Error, "fake error"
  ; "WARN", Some Warning, "fake warning"
  ; "INFO", Some Information, "fake info"
  ; "HINT", Some Hint, "fake hint"
  ; "NOSEV", None, "fake finding without severity"
  ; "MULTI", Some Error, "This expression has type int\n       but an expression was expected of type\n         string"
  ]
;;

let check () =
  match !latest with
  | None -> ()
  | Some _ when !awaiting > 0 -> ()
  | Some (uri, version, text) ->
    if String.is_substring text ~substring:"CRASH"
    then (
      eprintf "fake: crashed on CRASH\n%!";
      exit 3);
    let diagnostics =
      List.concat_mapi (String.split text ~on:'\n') ~f:(fun line text ->
        List.filter_map keywords ~f:(fun (keyword, severity, message) ->
          Option.map (String.substr_index text ~pattern:keyword) ~f:(fun byte ->
            diagnostic ?severity ~line ~character:(units text byte) message)))
    in
    publish ~version uri diagnostics;
    let other = Filename.concat (Filename.dirname (Lsp.Uri.to_path uri)) "other.ml" in
    (match In_channel.read_lines other with
     | exception _ -> ()
     | lines ->
       List.find_mapi lines ~f:(fun line text ->
         Option.map (String.substr_index text ~pattern:"OTHER") ~f:(fun byte ->
           diagnostic ~severity:Warning ~line ~character:(units text byte) "fake other"))
       |> Option.iter ~f:(fun d -> publish (Lsp.Uri.of_path other) [ d ]))
;;

let server_request id method_ params =
  incr awaiting;
  send (Request (Jsonrpc.Request.create ~id:(`Int id) ~method_ ~params ()))
;;

let handle (packet : Jsonrpc.Packet.t) =
  match packet with
  | Request { id; method_ = "initialize"; _ } ->
    if !fail_init
    then
      send
        (Response
           (Jsonrpc.Response.error
              id
              (Jsonrpc.Response.Error.make
                 ~code:InternalError
                 ~message:"fake: refuses to initialize"
                 ())))
    else (
      let positionEncoding : Types.PositionEncodingKind.t option =
        match !encoding with
        | "utf-8" -> Some UTF8
        | "utf-16" -> Some UTF16
        | _ -> None
      in
      let capabilities = Types.ServerCapabilities.create ?positionEncoding () in
      send
        (Response
           (Jsonrpc.Response.ok
              id
              (Types.InitializeResult.yojson_of_t
                 (Types.InitializeResult.create ~capabilities ())))))
  | Request { id; method_ = "shutdown"; _ } -> send (Response (Jsonrpc.Response.ok id `Null))
  | Request { id; method_; _ } ->
    send
      (Response
         (Jsonrpc.Response.error
            id
            (Jsonrpc.Response.Error.make ~code:MethodNotFound ~message:method_ ())))
  | Response { result = Ok _; _ } ->
    decr awaiting;
    check ()
  | Response { result = Error _; _ } -> eprintf "fake: client refused a request\n%!"
  | Notification notification ->
    (match Lsp.Client_notification.of_jsonrpc notification with
     | Ok Initialized when !request_first ->
       server_request
         1
         "workspace/configuration"
         (`Assoc [ "items", `List [ `Assoc [ "section", `String "ocaml" ] ] ]);
       server_request 2 "window/workDoneProgress/create" (`Assoc [ "token", `String "t" ])
     | Ok (TextDocumentDidOpen { textDocument = { uri; version; text; _ } }) ->
       latest := Some (uri, version, text);
       check ()
     | Ok (TextDocumentDidChange { textDocument = { uri; version }; contentChanges }) ->
       (match List.last contentChanges with
        | Some { text; _ } ->
          latest := Some (uri, version, text);
          check ()
        | None -> ())
     | Ok Exit -> exit 0
     | Ok _ | Error _ -> ())
  | Batch_response _ | Batch_call _ -> ()
;;

let () =
  let exit_at_start = ref false in
  Stdlib.Arg.parse
    [ "-encoding", Set_string encoding, ""
    ; "-fail-init", Set fail_init, ""
    ; "-exit-at-start", Set exit_at_start, ""
    ; "-request-first", Set request_first, ""
    ]
    ignore
    "fake_lsp";
  if !exit_at_start
  then (
    eprintf "fake: cannot start\n%!";
    exit 2);
  let rec loop () =
    match Io.read In_channel.stdin with
    | None -> ()
    | Some packet ->
      handle packet;
      loop ()
  in
  loop ()
;;
