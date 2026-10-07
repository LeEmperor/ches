open! Core
open! Async
module Feedback = Ches_error.Error
module Source_event = Ches_error.Source_event
module Source_request = Ches_error.Source_request
module Finding = Feedback.Diagnostics.Finding
module Cell_layout = Ches_core.Cell_layout
module Types = Lsp.Types

module Config = struct
  type t =
    { source : string
    ; prog : string
    ; args : string list
    ; applies_to : string -> bool
    ; language_id : string -> string
    ; root_markers : string list
    ; shutdown_grace : Time_ns.Span.t
    }

  let ocamllsp_language_id path =
    match snd (Filename.split_extension path) with
    | Some "mli" -> "ocaml.interface"
    | Some "mll" -> "ocaml.ocamllex"
    | Some "mly" -> "ocaml.menhir"
    | _ -> "ocaml"
  ;;

  let ocamllsp =
    { source = "ocamllsp"
    ; prog = "ocamllsp"
    ; args = []
    ; applies_to =
        (fun path ->
          match snd (Filename.split_extension path) with
          | Some ("ml" | "mli" | "mll" | "mly") -> true
          | _ -> false)
    ; language_id = ocamllsp_language_id
    ; root_markers =
        [ "dune-project"
        ; "dune-workspace"
        ; "*.opam"
        ; "opam"
        ; "esy.json"
        ; "package.json"
        ; ".git"
        ]
    ; shutdown_grace = Time_ns.Span.of_int_ms 1000
    }
  ;;

  let slang_server =
    { source = "slang-server"
    ; prog = "slang-server"
    ; args = []
    ; applies_to =
        (fun path ->
          match snd (Filename.split_extension path) with
          | Some ("sv" | "svh" | "v" | "vh") -> true
          | _ -> false)
    ; language_id =
        (fun path ->
          match snd (Filename.split_extension path) with
          | Some ("v" | "vh") -> "verilog"
          | _ -> "systemverilog")
    ; root_markers = [ ".slang"; ".git" ]
    ; shutdown_grace = Time_ns.Span.of_int_ms 1000
    }
  ;;

  let for_path path = List.find [ ocamllsp; slang_server ] ~f:(fun t -> t.applies_to path)

  let root t path = Workspace_root.find_first ~markers:t.root_markers path
end

module Convert = struct
  type encoding =
    | Utf8
    | Utf16
    | Utf32
  [@@deriving sexp_of]

  let encoding : Types.PositionEncodingKind.t option -> encoding = function
    | Some UTF8 -> Utf8
    | Some UTF32 -> Utf32
    | Some UTF16 | Some (Other _) | None -> Utf16
  ;;

  let severity : Types.DiagnosticSeverity.t option -> Feedback.Severity.t = function
    | Some Error | None -> Error
    | Some Warning -> Warning
    | Some Information -> Info
    | Some Hint -> Hint
  ;;

  let message text =
    String.split_on_chars text ~on:[ ' '; '\t'; '\n'; '\r' ]
    |> List.filter ~f:(Fn.non String.is_empty)
    |> String.concat ~sep:" "
  ;;

  (* The byte offset of the code point [character] units into [line]; the line's
     length past its end. *)
  let byte_offset encoding ~line ~character =
    let length = String.length line in
    let rec walk pos units =
      if pos >= length
      then length
      else (
        let decode = Stdlib.String.get_utf_8_uchar line pos in
        let bytes = Stdlib.Uchar.utf_decode_length decode in
        let size =
          match encoding with
          | Utf8 -> bytes
          | Utf32 -> 1
          | Utf16 ->
            if Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar decode) >= 0x10000 then 2 else 1
        in
        if units + size > character then pos else walk (pos + bytes) (units + size))
    in
    walk 0 0
  ;;

  let column ~cell_width encoding ~line ~character =
    let pos = byte_offset encoding ~line ~character:(Int.max 0 character) in
    Cell_layout.column (Cell_layout.glyphs ~width:cell_width line) ~pos ~tab_end:false + 1
  ;;
end

(* Lsp's framing over Async readers and writers. *)
module Io =
  Lsp.Io.Make
    (struct
      type 'a t = 'a Deferred.t

      let return = return
      let raise = raise

      module O = struct
        let ( let+ ) d f = Deferred.map d ~f
        let ( let* ) d f = Deferred.bind d ~f
      end
    end)
    (struct
      type input = Reader.t
      type output = Writer.t

      let read_line reader =
        match%map Reader.read_line reader with
        | `Ok line -> Some line
        | `Eof -> None
      ;;

      let read_exactly reader length =
        let buffer = Bytes.create length in
        match%map Reader.really_read reader buffer with
        | `Ok -> Some (Bytes.to_string buffer)
        | `Eof _ -> None
      ;;

      let write writer strings =
        List.iter strings ~f:(Writer.write writer);
        return ()
      ;;
    end)

module Document = struct
  type t =
    { resource : string (** As Ches names it. *)
    ; file : string (** Lexically normalized absolute path; symlink aliases stay distinct. *)
    ; uri : Lsp.Uri.t
    ; revision : int
    ; text : string
    }
end

type session =
  { process : Process.t
  ; mutable next_id : int
  ; pending : (Jsonrpc.Response.t -> unit) Int.Table.t
  ; mutable encoding : Convert.encoding
  ; mutable initialized : bool
  ; mutable opened : Document.t option (** The document as last sent to the server. *)
  ; mutable closed : bool (** Nothing more is written to it. *)
  ; mutable stderr_last : string option
  }

type t =
  { config : Config.t
  ; root : string
  ; cell_width : Cell_layout.Width.t
  ; emit : Source_event.t -> unit
  ; mutable session : session option
  (** The current session. Whatever an earlier one says, or how it ends, is not
      reported. *)
  ; mutable generation : int (** Increased by each start, so a late launch is dropped. *)
  ; mutable document : Document.t option
  ; recent : (int * string) Queue.t
  (** The texts of the newest revisions sent, oldest first, to place a published list's
      positions in the text it describes. *)
  ; mutable stopped : bool
  }

let recent_capacity = 32

let canonical file =
  let file =
    if Filename.is_relative file then Filename.concat (Core_unix.getcwd ()) file else file
  in
  Ches_core.Resource.normalize ~cwd:(Core_unix.getcwd ()) file
;;

let display_path file =
  Option.value
    (String.chop_prefix file ~prefix:(Core_unix.getcwd () ^ "/"))
    ~default:file
;;

let find_program prog =
  let executable file =
    match Core_unix.access file [ `Exec ] with
    | Ok () -> Sys_unix.is_file_exn file
    | Error _ -> false
  in
  if String.mem prog '/'
  then Option.some_if (executable prog) prog
  else
    Option.value (Sys.getenv "PATH") ~default:""
    |> String.split ~on:':'
    |> List.filter ~f:(Fn.non String.is_empty)
    |> List.find_map ~f:(fun dir ->
      let file = Filename.concat dir prog in
      Option.some_if (executable file) file)
;;

let current t session = Option.exists t.session ~f:(phys_equal session)

let send session packet =
  if not session.closed then don't_wait_for (Io.write (Process.stdin session.process) packet)
;;

let notify session notification =
  send session (Notification (Lsp.Client_notification.to_jsonrpc notification))
;;

let request session request ~on_response =
  let id = session.next_id in
  session.next_id <- id + 1;
  Hashtbl.set session.pending ~key:id ~data:on_response;
  send session (Request (Lsp.Client_request.to_jsonrpc_request request ~id:(`Int id)))
;;

let kill session =
  ignore (Process.send_signal_compat session.process Signal.kill : [ `Ok | `No_such_process ])
;;

(* Report the session's end once, unless Ches ended it. *)
let report_stop t session ~reason =
  if current t session
  then (
    t.session <- None;
    let reason =
      match session.stderr_last with
      | Some line -> sprintf "%s: %s" reason line
      | None -> reason
    in
    t.emit (Stopped { source = t.config.source; root = t.root; reason }))
;;

let fail t session ~reason =
  report_stop t session ~reason;
  kill session
;;

let item t (document : Document.t) =
  Types.TextDocumentItem.create
    ~languageId:(t.config.language_id document.file)
    ~text:document.text
    ~uri:document.uri
    ~version:document.revision
;;

(* Bring the server's copy of the document up to date with [t.document]. *)
let synchronize t session =
  match t.document, session.opened with
  | _ when not session.initialized -> ()
  | None, _ -> ()
  | Some document, Some opened when String.equal document.file opened.file ->
    if document.revision <> opened.revision
    then (
      session.opened <- Some document;
      notify
        session
        (TextDocumentDidChange
           (Types.DidChangeTextDocumentParams.create
              ~textDocument:
                (Types.VersionedTextDocumentIdentifier.create
                   ~uri:document.uri
                   ~version:document.revision)
              ~contentChanges:
                [ Types.TextDocumentContentChangeEvent.create ~text:document.text () ])))
  | Some document, opened ->
    Option.iter opened ~f:(fun opened ->
      notify
        session
        (TextDocumentDidClose
           (Types.DidCloseTextDocumentParams.create
              ~textDocument:(Types.TextDocumentIdentifier.create ~uri:opened.uri))));
    session.opened <- Some document;
    notify
      session
      (TextDocumentDidOpen
         (Types.DidOpenTextDocumentParams.create ~textDocument:(item t document)))
;;

(* The line [index] (zero-based) of the text a published list describes: for the open
   document, the text of its version, else the newest; for another file, the file on
   disk, read only when a column needs it. *)
let line_source t ~(document : Document.t option) ~version ~file ~needed =
  let lines text = Some (Array.of_list (String.split text ~on:'\n')) in
  match document with
  | Some document ->
    let text =
      Option.bind version ~f:(fun version ->
        Queue.find_map t.recent ~f:(fun (revision, text) ->
          Option.some_if (revision = version) text))
    in
    return (lines (Option.value text ~default:document.text))
  | None when not needed -> return None
  | None ->
    (match%map Monitor.try_with (fun () -> Reader.file_contents file) with
     | Ok text -> lines text
     | Error _ -> None)
;;

let publish t session (params : Types.PublishDiagnosticsParams.t) =
  let file = canonical (Lsp.Uri.to_path params.uri) in
  let document =
    Option.filter t.document ~f:(fun document -> String.equal document.file file)
  in
  let needed =
    List.exists params.diagnostics ~f:(fun d -> d.range.start.character > 0)
  in
  let%map lines = line_source t ~document ~version:params.version ~file ~needed in
  let findings =
    List.map params.diagnostics ~f:(fun (d : Types.Diagnostic.t) : Finding.t ->
      let line = d.range.start.line in
      let column =
        match Option.bind lines ~f:(fun lines -> Array.get_opt lines line) with
        | Some text ->
          let text = String.chop_suffix_if_exists text ~suffix:"\r" in
          Convert.column
            ~cell_width:t.cell_width
            session.encoding
            ~line:text
            ~character:d.range.start.character
        | None -> 1
      in
      let message =
        match d.message with
        | `String message -> message
        | `MarkupContent { value; _ } -> value
      in
      { severity = Convert.severity d.severity
      ; message = Convert.message message
      ; location = Some { line = line + 1; column }
      })
  in
  if current t session
  then
    t.emit
      (Diagnostics
         { source = t.config.source
         ; resource =
             Option.value_map document ~f:(fun d -> d.resource) ~default:(display_path file)
         ; revision = Option.bind document ~f:(fun _ -> params.version)
         ; findings
         })
;;

(* Answers to the requests ocamllsp makes of a client; "method not found" otherwise. *)
let answer t session (request : Jsonrpc.Request.t) =
  let ok json = send session (Response (Jsonrpc.Response.ok request.id json)) in
  match request.method_ with
  | "window/workDoneProgress/create"
  | "client/registerCapability"
  | "client/unregisterCapability"
  | "window/showMessageRequest" -> ok `Null
  | "workspace/configuration" ->
    let items =
      match request.params with
      | Some (`Assoc fields) ->
        (match List.Assoc.find fields "items" ~equal:String.equal with
         | Some (`List items) -> items
         | _ -> [])
      | _ -> []
    in
    ok (`List (List.map items ~f:(fun _ -> `Null)))
  | "workspace/workspaceFolders" ->
    let uri = Lsp.Uri.of_path t.root in
    ok
      (`List
          [ Types.WorkspaceFolder.yojson_of_t
              (Types.WorkspaceFolder.create ~name:(Filename.basename t.root) ~uri)
          ])
  | method_ ->
    send
      session
      (Response
         (Jsonrpc.Response.error
            request.id
            (Jsonrpc.Response.Error.make
               ~code:MethodNotFound
               ~message:(sprintf "ches does not handle %s" method_)
               ())))
;;

let handle t session (packet : Jsonrpc.Packet.t) =
  match packet with
  | Notification notification ->
    (match Lsp.Server_notification.of_jsonrpc notification with
     | Ok (PublishDiagnostics params) -> publish t session params
     | Ok _ | Error _ -> return ())
  | Request request ->
    answer t session request;
    return ()
  | Response response ->
    (match response.id with
     | `Int id ->
       Option.iter (Hashtbl.find_and_remove session.pending id) ~f:(fun f -> f response)
     | `String _ -> ());
    return ()
  | Batch_response _ | Batch_call _ -> return ()
;;

let initialize t session =
  let uri = Lsp.Uri.of_path t.root in
  let params =
    Types.InitializeParams.create
      ~capabilities:
        (Types.ClientCapabilities.create
           ~general:(Types.GeneralClientCapabilities.create ~positionEncodings:[ UTF8; UTF16 ] ())
           ~textDocument:
             (Types.TextDocumentClientCapabilities.create
                ~publishDiagnostics:
                  (Types.PublishDiagnosticsClientCapabilities.create ~versionSupport:true ())
                ~synchronization:
                  (Types.TextDocumentSyncClientCapabilities.create ~didSave:true ())
                ())
           ())
      ~clientInfo:(Types.InitializeParams.create_clientInfo ~name:"ches" ())
      ~processId:(Pid.to_int (Core_unix.getpid ()))
      ~rootUri:uri
      ~workspaceFolders:
        (Some [ Types.WorkspaceFolder.create ~name:(Filename.basename t.root) ~uri ])
      ()
  in
  let initialize = Lsp.Client_request.Initialize params in
  request session initialize ~on_response:(fun response ->
    if current t session
    then (
      match response.result with
      | Error error ->
        fail t session ~reason:(sprintf "initialize failed: %s" error.message)
      | Ok json ->
        (match Lsp.Client_request.response_of_json initialize json with
         | exception exn ->
           fail t session ~reason:(sprintf "initialize failed: %s" (Exn.to_string exn))
         | result ->
           session.encoding <- Convert.encoding result.capabilities.positionEncoding;
           session.initialized <- true;
           notify session Initialized;
           t.emit (Started { source = t.config.source; root = t.root });
           synchronize t session)))
;;

let rec read t session =
  match%bind Io.read (Process.stdout session.process) with
  | None -> return ()
  | Some packet ->
    let%bind () = handle t session packet in
    read t session
;;

let run t session =
  don't_wait_for
    (Pipe.iter_without_pushback
       (Reader.lines (Process.stderr session.process))
       ~f:(fun line ->
         let line = String.strip line in
         if not (String.is_empty line) then session.stderr_last <- Some line));
  initialize t session;
  let%bind result = Monitor.try_with (fun () -> read t session) in
  (match result with
   | Ok () -> ()
   | Error exn ->
     fail t session ~reason:(sprintf "protocol error: %s" (Exn.to_string (Monitor.extract_exn exn))));
  let%map status = Process.wait session.process in
  report_stop t session ~reason:(Unix.Exit_or_signal.to_string_hum status)
;;

let start_session t =
  match find_program t.config.prog with
  | None ->
    t.emit
      (Unavailable
         { source = t.config.source
         ; root = t.root
         ; reason = sprintf "%s not found on PATH" t.config.prog
         })
  | Some prog ->
    t.generation <- t.generation + 1;
    let generation = t.generation in
    let superseded () = t.stopped || t.generation <> generation in
    don't_wait_for
      (match%bind
         Process.create ~prog ~args:t.config.args ~working_dir:t.root ~argv0:t.config.prog ()
       with
       | Error error ->
         if not (superseded ())
         then
           t.emit
             (Stopped
                { source = t.config.source
                ; root = t.root
                ; reason = sprintf "could not start: %s" (Error.to_string_hum error)
                });
         return ()
       | Ok process ->
         let session =
           { process
           ; next_id = 1
           ; pending = Int.Table.create ()
           ; encoding = Utf16
           ; initialized = false
           ; opened = None
           ; closed = false
           ; stderr_last = None
           }
         in
         let writer = Process.stdin process in
         Writer.set_raise_when_consumer_leaves writer false;
         (* A write to a server that has gone is reported by its exit, not here. *)
         Monitor.detach_and_iter_errors (Writer.monitor writer) ~f:ignore;
         if superseded ()
         then (
           kill session;
           return ())
         else (
           t.session <- Some session;
           run t session))
;;

(* End the session without reporting it: [shutdown] and [exit] if it was initialized,
   then a kill if it outlives the grace period. *)
let end_session t =
  Option.iter t.session ~f:(fun session ->
    t.session <- None;
    let initialized = session.initialized in
    let exited = Process.wait session.process |> Deferred.ignore_m in
    if initialized
    then
      request session Shutdown ~on_response:(fun _ ->
        notify session Exit;
        session.closed <- true)
    else session.closed <- true;
    let ended =
      match%map Clock_ns.with_timeout t.config.shutdown_grace exited with
      | `Result () -> ()
      | `Timeout ->
        session.closed <- true;
        kill session
    in
    (* Ches quitting: hold Async's shutdown, and so the exit, until the server is gone. *)
    if t.stopped then Shutdown.don't_finish_before ended else don't_wait_for ended)
;;

let handle_request t (request : Source_request.t) =
  match request with
  | Document_opened _ -> ()
  | Document_closed { resource } ->
    (match t.document with
     | Some document when String.equal document.resource resource ->
       Option.iter t.session ~f:(fun session ->
         Option.iter session.opened ~f:(fun opened ->
           notify session (TextDocumentDidClose (Types.DidCloseTextDocumentParams.create
             ~textDocument:(Types.TextDocumentIdentifier.create ~uri:opened.uri))));
         session.opened <- None);
       t.document <- None;
       Queue.clear t.recent
     | _ -> ())
  | Document_changed { resource; text; revision } ->
    let file = canonical resource in
    let document =
      { Document.resource; file; uri = Lsp.Uri.of_path file; revision; text }
    in
    t.document <- Some document;
    Queue.enqueue t.recent (revision, text);
    while Queue.length t.recent > recent_capacity do
      ignore (Queue.dequeue_exn t.recent : int * string)
    done;
    Option.iter t.session ~f:(synchronize t)
   | Document_saved { resource; revision = _ } ->
    Option.iter t.session ~f:(fun session ->
       Option.iter (Option.filter session.opened ~f:(fun opened -> String.equal opened.resource resource)) ~f:(fun opened ->
        notify
          session
          (DidSaveTextDocument
             (Types.DidSaveTextDocumentParams.create
                ~textDocument:(Types.TextDocumentIdentifier.create ~uri:opened.uri)
                ()))))
  | Restart ->
    end_session t;
    start_session t
  | Kill -> ()
;;

let start ?(config = Config.ocamllsp) ~cell_width ~root () =
  Source.create (fun ~emit ->
    let t =
      { config
      ; root
      ; cell_width
      ; emit
      ; session = None
      ; generation = 0
      ; document = None
      ; recent = Queue.create ()
      ; stopped = false
      }
    in
    start_session t;
    { handle = handle_request t
    ; stop =
        (fun () ->
          t.stopped <- true;
          end_session t)
    })
;;
