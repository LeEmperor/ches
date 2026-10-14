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
let documents = String.Table.create ()
let log_file = ref ""
let late_on_close = ref false
let late = ref None
let replay_on_save = ref false
let ignore_shutdown = ref false
let unversioned = ref false
let delay_init = ref false
let first_documents = String.Table.create ()
let sync = ref "full"
let payload_log = ref ""
let gap_on_save = ref false
let close_stdout = ref false

let log method_ =
  if not (String.is_empty !log_file) then
    Out_channel.with_file !log_file ~append:true ~f:(fun out ->
      fprintf out "%d %s\n" (Pid.to_int (Core_unix.getpid ())) method_)
;;

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
         count (pos + Stdlib.Uchar.utf_decode_length d)
           (acc + if String.equal !encoding "utf-32" then 1 else if u >= 0x10000 then 2 else 1))
    in
    count 0 0
;;

let offset text (position : Types.Position.t) =
  let rec find_line pos line =
    if line = position.line then pos
    else if pos >= String.length text then failwith "invalid incremental line"
    else if Char.equal text.[pos] '\r' then
      let next = if pos + 1 < String.length text && Char.equal text.[pos + 1] '\n'
        then pos + 2 else pos + 1 in
      find_line next (line + 1)
    else if Char.equal text.[pos] '\n' then find_line (pos + 1) (line + 1)
    else find_line (pos + 1) line
  in
  let start = find_line 0 0 in
  let rec end_line pos = if pos >= String.length text || Char.equal text.[pos] '\r'
    || Char.equal text.[pos] '\n' then pos else end_line (pos + 1) in
  let line = String.sub text ~pos:start ~len:(end_line start - start) in
  let rec walk byte =
    if units line byte = position.character then byte
    else if byte >= String.length line then failwith "invalid incremental position"
    else walk (byte + Stdlib.Uchar.utf_decode_length (Stdlib.String.get_utf_8_uchar line byte))
  in
  start + walk 0
;;

let apply_change text (change : Types.TextDocumentContentChangeEvent.t) =
  match change.range with
  | None ->
    assert (not (List.mem [ "incremental"; "options" ] !sync ~equal:String.equal)
      || String.equal !encoding "unknown"
      || not (Stdlib.String.is_valid_utf_8 text && Stdlib.String.is_valid_utf_8 change.text));
    change.text
  | Some range ->
    assert (not (String.equal !sync "full"));
    let start = offset text range.start and end_ = offset text range.end_ in
    String.prefix text start ^ change.text ^ String.drop_prefix text end_
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
     publish ?version:(Option.some_if (not !unversioned) version) uri diagnostics;
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
  (match packet with
   | Notification n when not (String.is_empty !payload_log) ->
     Out_channel.with_file !payload_log ~append:true ~f:(fun out ->
       Out_channel.output_string out (Yojson.Safe.to_string (Jsonrpc.Notification.yojson_of_t n) ^ "\n"))
   | _ -> ());
  (match packet with
   | Request r -> log r.method_
   | Notification n -> log n.method_
   | _ -> ());
  match packet with
   | Request { id; method_ = "initialize"; _ } ->
     if !delay_init then ignore (Core_unix.nanosleep 0.1 : float);
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
        | "utf-32" -> Some UTF32
        | "unknown" -> Some (Other "unsupported-encoding")
        | _ -> None
      in
       let kind : Types.TextDocumentSyncKind.t = match !sync with
         | "incremental" | "options" -> Incremental | "none" -> None | _ -> Full in
       let textDocumentSync = if String.equal !sync "options"
         then `TextDocumentSyncOptions (Types.TextDocumentSyncOptions.create ~change:kind ~openClose:true
           ~save:(`SaveOptions (Types.SaveOptions.create ~includeText:true ())) ())
         else `TextDocumentSyncKind kind in
       let textDocumentSync = Option.some_if (not (String.equal !sync "absent")) textDocumentSync in
       let capabilities = Types.ServerCapabilities.create ?positionEncoding ?textDocumentSync () in
      send
        (Response
           (Jsonrpc.Response.ok
              id
              (Types.InitializeResult.yojson_of_t
                 (Types.InitializeResult.create ~capabilities ())))))
   | Request { method_ = "shutdown"; _ } when !ignore_shutdown -> ()
   | Request { id; method_ = "shutdown"; _ } -> send (Response (Jsonrpc.Response.ok id `Null))
  | Request { id; method_; _ } ->
    send
      (Response
         (Jsonrpc.Response.error
            id
            (Jsonrpc.Response.Error.make ~code:MethodNotFound ~message:method_ ())))
   | Response { result = Ok _; _ } ->
     decr awaiting;
     Hashtbl.iter documents ~f:(fun document -> latest := Some document; check ())
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
        if !close_stdout then (
          Out_channel.close Out_channel.stdout;
          (* Deliberately survive EOF without consuming shutdown requests. *)
          while true do ignore (Core_unix.nanosleep 1. : float) done);
        Option.iter !late ~f:(fun (old_uri, old_version) ->
          publish ~version:old_version old_uri [ diagnostic ~line:0 ~character:0 "late closed version" ];
          publish old_uri [ diagnostic ~line:0 ~character:0 "late unversioned" ]);
        late := None;
        Hashtbl.set documents ~key:(Lsp.Uri.to_path uri) ~data:(uri, version, text);
        Hashtbl.set first_documents ~key:(Lsp.Uri.to_path uri) ~data:(uri, version, text);
        latest := Some (uri, version, text);
       check ()
     | Ok (TextDocumentDidChange { textDocument = { uri; version }; contentChanges }) ->
        (match Hashtbl.find documents (Lsp.Uri.to_path uri) with
          | Some (_, _, old_text) ->
            let text = List.fold contentChanges ~init:old_text ~f:apply_change in
           Hashtbl.set documents ~key:(Lsp.Uri.to_path uri) ~data:(uri, version, text);
          latest := Some (uri, version, text);
          check ()
        | None -> ())
      | Ok (TextDocumentDidClose { textDocument = { uri } }) ->
        Option.iter (Hashtbl.find_and_remove documents (Lsp.Uri.to_path uri)) ~f:(fun (_, version, _) ->
          if !late_on_close then late := Some (uri, version))
       | Ok (DidSaveTextDocument { textDocument = { uri }; _ }) when !replay_on_save ->
         if !gap_on_save then Option.iter (Hashtbl.find documents (Lsp.Uri.to_path uri)) ~f:(fun (_, version, _) ->
           publish ~version:(version - 1) uri [ diagnostic ~line:0 ~character:0 "unsent gap version" ]);
        Option.iter (Hashtbl.find first_documents (Lsp.Uri.to_path uri)) ~f:(fun document ->
          latest := Some document; check ())
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
     ; "-log", Set_string log_file, ""
     ; "-late-on-close", Set late_on_close, ""
     ; "-replay-on-save", Set replay_on_save, ""
     ; "-ignore-shutdown", Set ignore_shutdown, ""
     ; "-unversioned", Set unversioned, ""
     ; "-delay-init", Set delay_init, ""
     ; "-sync", Set_string sync, ""
     ; "-payload-log", Set_string payload_log, ""
     ; "-gap-on-save", Set gap_on_save, ""
     ; "-close-stdout", Set close_stdout, ""
    ]
    ignore
     "fake_lsp";
   log "spawn";
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
