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

  let root t path = Workspace_root.find_nearest ~markers:t.root_markers path
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
    ; version : int
    ; text : string
    ; owner : int option
    ; recent : (int * int * string) Queue.t
    (** Wire version, editor revision, text; oldest first, at most 32 entries. *)
    }
end

type session =
  { process : Process.t
  ; mutable next_id : int
  ; pending : (Jsonrpc.Response.t -> unit) Int.Table.t
  ; mutable encoding : Convert.encoding
  ; mutable initialized : bool
  ; mutable sync_kind : Types.TextDocumentSyncKind.t
  ; mutable save_text : bool
  ; changes : Clock_ns.Event.t_unit String.Table.t
  ; opened : Document.t String.Table.t
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
  ; documents : Document.t String.Table.t
  ; owners : int String.Table.t
  ; versions : int String.Table.t
  (** Last wire version per URI, including closed URIs. Tombstones retain no text
       and prevent late closed-document output becoming workspace diagnostics. *)
  ; saves : String.Hash_set.t
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

let cancel_change session file =
  Option.iter (Hashtbl.find_and_remove session.changes file) ~f:(fun timer ->
    Clock_ns.Event.abort_if_possible timer ())
;;

let cancel_changes session =
  Hashtbl.iter session.changes ~f:(fun timer -> Clock_ns.Event.abort_if_possible timer ());
  Hashtbl.clear session.changes
;;

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
    cancel_changes session;
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
    ~version:document.version
;;

(* Diff only at flush time, against the text actually sent, never an unsent edit.
   The highlight helper preserves UTF-8 code-point boundaries. CRLF needs an
   additional boundary adjustment: LSP cannot address the middle of a CRLF. *)
let content_change encoding ~old_text ~text =
  let full () = Types.TextDocumentContentChangeEvent.create ~text () in
  match Ches_highlight.Edit.between ~old_source:old_text ~new_source:text with
  | exception Invalid_argument _ -> full ()
  | None ->
    let p = Types.Position.create ~line:0 ~character:0 in
    Types.TextDocumentContentChangeEvent.create
      ~range:(Types.Range.create ~start:p ~end_:p) ~text:"" ()
  | Some edit ->
    let inside_crlf source offset =
      offset > 0 && offset < String.length source
      && Char.equal source.[offset - 1] '\r' && Char.equal source.[offset] '\n'
    in
    let start = if inside_crlf old_text edit.start_byte || inside_crlf text edit.start_byte
      then edit.start_byte - 1 else edit.start_byte in
    let extend = inside_crlf old_text edit.old_end_byte || inside_crlf text edit.new_end_byte in
    let old_end = edit.old_end_byte + Bool.to_int extend in
    let new_end = edit.new_end_byte + Bool.to_int extend in
    let position stop =
      let rec walk pos line character =
        if pos >= stop then Types.Position.create ~line ~character
        else if Char.equal old_text.[pos] '\r' then
          let next = if pos + 1 < String.length old_text && Char.equal old_text.[pos + 1] '\n'
            then pos + 2 else pos + 1 in
          walk next (line + 1) 0
        else if Char.equal old_text.[pos] '\n' then walk (pos + 1) (line + 1) 0
        else (
          let d = Stdlib.String.get_utf_8_uchar old_text pos in
          let bytes = Stdlib.Uchar.utf_decode_length d in
          let units = match encoding with
            | Convert.Utf8 -> bytes
            | Utf32 -> 1
            | Utf16 -> if Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar d) >= 0x10000 then 2 else 1 in
          walk (pos + bytes) line (character + units))
      in
      walk 0 0 0
    in
    Types.TextDocumentContentChangeEvent.create
      ~range:(Types.Range.create ~start:(position start) ~end_:(position old_end))
      ~text:(String.sub text ~pos:start ~len:(new_end - start)) ()
;;

let synchronize_document t session (document : Document.t) =
  if session.initialized
  then (
    let remember () =
      if not (Queue.exists document.recent ~f:(fun (sent, _, _) -> sent = document.version))
      then (
        Queue.enqueue document.recent (document.version, document.revision, document.text);
        while Queue.length document.recent > recent_capacity do
          ignore (Queue.dequeue_exn document.recent : int * int * string)
        done)
    in
    match Hashtbl.find session.opened document.file with
    | Some opened ->
       if document.version <> opened.version
          && (match session.sync_kind with None -> false | Full | Incremental -> true)
      then (
        remember ();
        Hashtbl.set session.opened ~key:document.file ~data:document;
        notify session
          (TextDocumentDidChange
             (Types.DidChangeTextDocumentParams.create
                ~textDocument:
                  (Types.VersionedTextDocumentIdentifier.create
                     ~uri:document.uri ~version:document.version)
                ~contentChanges:
                   [ (match session.sync_kind with
                      | Incremental -> content_change session.encoding ~old_text:opened.text ~text:document.text
                      | Full | None -> Types.TextDocumentContentChangeEvent.create ~text:document.text ()) ])))
    | None ->
      remember ();
      Hashtbl.set session.opened ~key:document.file ~data:document;
      notify session
        (TextDocumentDidOpen
           (Types.DidOpenTextDocumentParams.create ~textDocument:(item t document))))
;;

let flush_document t session file =
  cancel_change session file;
  if current t session && not session.closed then
    Option.iter (Hashtbl.find t.documents file) ~f:(synchronize_document t session)
;;

let queue_document t session (document : Document.t) =
  if session.initialized && not session.closed then
    if not (Hashtbl.mem session.opened document.file) then synchronize_document t session document
    else if (match session.sync_kind with None -> false | Full | Incremental -> true)
            && not (Hashtbl.mem session.changes document.file) then (
      let timer = Clock_ns.Event.run_after (Time_ns.Span.of_int_ms 25)
        (fun file -> flush_document t session file) document.file in
      Hashtbl.set session.changes ~key:document.file ~data:timer)
;;

let save_document t session file =
  if session.initialized then (
    flush_document t session file;
    Option.iter (Hashtbl.find session.opened file) ~f:(fun opened ->
      let text = Option.value_map (Hashtbl.find t.documents file)
        ~default:opened.text ~f:(fun document -> document.text) in
      notify session (DidSaveTextDocument (Types.DidSaveTextDocumentParams.create
        ?text:(Option.some_if session.save_text text)
        ~textDocument:(Types.TextDocumentIdentifier.create ~uri:opened.uri) ())));
    Hash_set.remove t.saves file)
;;

let synchronize t session =
  Hashtbl.iter t.documents ~f:(synchronize_document t session)
;;

(* The line [index] (zero-based) of the text a published list describes: for the open
   document, the text of its version, else the newest; for another file, the file on
   disk, read only when a column needs it. *)
let line_source ~(document : Document.t option) ~version ~file ~needed =
  let lines text = Some (Array.of_list (String.split text ~on:'\n')) in
  match document with
  | Some document ->
    let text =
      Option.bind version ~f:(fun version ->
        Queue.find_map document.recent ~f:(fun (sent, _, text) ->
          Option.some_if (sent = version) text))
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
  let document = Hashtbl.find t.documents file in
  let revision =
    Option.bind document ~f:(fun document ->
      Option.bind params.version ~f:(fun version ->
        Queue.find_map document.recent ~f:(fun (sent, revision, _) ->
          Option.some_if (sent = version) revision)))
  in
  let valid =
    match document with
    | None -> not (Hashtbl.mem t.versions file)
    | Some _ ->
      (match params.version with
        | None -> true
       | Some _ -> Option.is_some revision)
  in
  let needed =
    List.exists params.diagnostics ~f:(fun d -> d.range.start.character > 0)
  in
  let%map lines =
    if valid && current t session
    then line_source ~document ~version:params.version ~file ~needed
    else return None
  in
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
  if valid && current t session
     && (match document, Hashtbl.find t.documents file with
         | None, None -> true
         | Some old, Some now ->
            String.equal old.resource now.resource && [%equal: int option] old.owner now.owner
            && phys_equal old.recent now.recent
         | _ -> false)
  then (
    let event =
      Source_event.Diagnostics
        { source = t.config.source
        ; resource =
            Option.value_map document ~f:(fun d -> d.resource) ~default:(display_path file)
        ; revision
        ; findings
        }
    in
    t.emit
      (match document with
       | Some { owner = Some generation; resource; _ } ->
         Owned { resource; generation; event }
       | _ -> event))
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
            ~general:(Types.GeneralClientCapabilities.create ~positionEncodings:[ UTF8; UTF16; UTF32 ] ())
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
            session.sync_kind <- (match result.capabilities.textDocumentSync with
              | Some (`TextDocumentSyncKind kind) -> kind
              | Some (`TextDocumentSyncOptions options) -> Option.value options.change ~default:None
              | None -> None);
            (* Unknown encodings cannot produce reliable ranges. A full event is
               also legal for incremental sync, and carries no positions. *)
            (match result.capabilities.positionEncoding, session.sync_kind with
             | Some (Other _), Incremental -> session.sync_kind <- Full
             | _ -> ());
            session.save_text <- (match result.capabilities.textDocumentSync with
              | Some (`TextDocumentSyncOptions { save = Some (`SaveOptions options); _ }) ->
                Option.value options.includeText ~default:false
              | _ -> false);
            session.initialized <- true;
            Hashtbl.iter t.documents ~f:(fun document -> Queue.clear document.recent);
           notify session Initialized;
           t.emit (Started { source = t.config.source; root = t.root });
            synchronize t session;
            List.iter (Hash_set.to_list t.saves) ~f:(save_document t session))))
;;

let rec read t session =
  match%bind Io.read (Process.stdout session.process) with
  | None -> return ()
  | Some packet ->
    let%bind () = handle t session packet in
    read t session
;;

let close_pipes session =
  cancel_changes session;
  session.closed <- true;
  Hashtbl.clear session.pending;
  Deferred.all_unit
    [ Reader.close (Process.stdout session.process)
    ; Reader.close (Process.stderr session.process)
    ; Writer.close ~force_close:Deferred.unit (Process.stdin session.process)
    ]
;;

let run t session =
  let stderr =
    Pipe.iter_without_pushback
        (Reader.lines (Process.stderr session.process))
        ~f:(fun line ->
          let line = String.strip line in
          if not (String.is_empty line) then session.stderr_last <- Some line)
  in
  initialize t session;
  let reading = Monitor.try_with (fun () -> read t session) in
  let%bind outcome = Deferred.choose
    [ Deferred.choice reading (fun result -> `Read result)
    ; Deferred.choice (Process.wait session.process) (fun status -> `Exit status)
    ] in
  let%bind status = match outcome with
    | `Exit status -> return status
    | `Read result ->
      (match result with
       | Ok () -> ()
       | Error exn ->
         fail t session ~reason:(sprintf "protocol error: %s" (Exn.to_string (Monitor.extract_exn exn))));
      (* EOF is not proof of process exit. A server can close stdout and keep
         running; do not retain its timers/process or hold shutdown forever.
         Allow normal exits to preserve their status/stderr before forcing it. *)
      let%bind ended = Clock_ns.with_timeout t.config.shutdown_grace (Process.wait session.process) in
      (match ended with
       | `Result _ -> ()
       | `Timeout -> fail t session ~reason:"protocol stream closed but server did not exit");
      Process.wait session.process
  in
  (* Drain the final stderr line, but do not hang on descendants inheriting pipes. *)
  let%bind _ = Clock_ns.with_timeout (Time_ns.Span.of_int_ms 50) stderr in
  report_stop t session ~reason:(Unix.Exit_or_signal.to_string_hum status);
  let%bind () = close_pipes session in
  Deferred.ignore_m reading
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
    let launch =
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
            ; sync_kind = None
            ; save_text = false
            ; changes = String.Table.create ()
           ; opened = String.Table.create ()
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
           let%bind _ = Process.wait process in
           close_pipes session)
         else (
           t.session <- Some session;
           run t session))
    in
    don't_wait_for launch;
    Shutdown.don't_finish_before launch
;;

(* End the session without reporting it: [shutdown] and [exit] if it was initialized,
   then a kill if it outlives the grace period. *)
let end_session t =
  Option.iter t.session ~f:(fun session ->
    cancel_changes session;
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

let rec handle_request t (request : Source_request.t) =
  match request with
  | Document_opened { resource; generation } ->
    handle_request t (Document_closed { resource });
    Hashtbl.set t.owners ~key:resource ~data:generation
  | Document_closed { resource } ->
    let file = canonical resource in
    Hashtbl.remove t.owners resource;
    (match Hashtbl.find t.documents file with
     | Some document when String.equal document.resource resource ->
       Hash_set.remove t.saves file;
       Option.iter t.session ~f:(fun session ->
         cancel_change session file;
         Option.iter (Hashtbl.find_and_remove session.opened file) ~f:(fun opened ->
           notify session
             (TextDocumentDidClose
                (Types.DidCloseTextDocumentParams.create
                   ~textDocument:(Types.TextDocumentIdentifier.create ~uri:opened.uri)))));
       Hashtbl.remove t.documents file
     | _ -> ())
  | Document_changed { resource; text; revision } ->
    let file = canonical resource in
    let previous = Hashtbl.find t.documents file in
    if Option.exists previous ~f:(fun d -> not (String.equal d.resource resource))
    then (
      let event =
        Source_event.Unavailable
          { source = t.config.source
          ; root = t.root
          ; reason = "another open resource has the same lexical LSP URI"
          }
      in
      t.emit
        (match Hashtbl.find t.owners resource with
         | Some generation -> Owned { resource; generation; event }
         | None -> event))
    else (
       let recent = match previous with Some d -> d.recent | None -> Queue.create () in
      let last = Hashtbl.find t.versions file in
      let version = Option.value_map last ~default:revision ~f:(fun n -> Int.max revision (n + 1)) in
      Hashtbl.set t.versions ~key:file ~data:version;
      let document =
        { Document.resource
        ; file
        ; uri = (match previous with Some d -> d.uri | None -> Lsp.Uri.of_path file)
        ; revision
        ; version
        ; text
        ; owner = Hashtbl.find t.owners resource
        ; recent
        }
      in
      Hashtbl.set t.documents ~key:file ~data:document;
       Option.iter t.session ~f:(fun session -> queue_document t session document))
  | Document_saved { resource; revision = _ } ->
     let file = canonical resource in
     if Option.exists (Hashtbl.find t.documents file) ~f:(fun d -> String.equal d.resource resource)
     then (
       Hash_set.add t.saves file;
       Option.iter t.session ~f:(fun session -> save_document t session file))
  | Restart ->
    t.generation <- t.generation + 1;
    end_session t;
    start_session t
  | Kill -> ()
;;

let driver ~config ~cell_width ~root ~emit =
  let t =
    { config
    ; root
    ; cell_width
    ; emit
    ; session = None
    ; generation = 0
    ; documents = String.Table.create ()
    ; owners = String.Table.create ()
     ; versions = String.Table.create ()
     ; saves = String.Hash_set.create ()
    ; stopped = false
    }
  in
  start_session t;
  { Source.Driver.handle = handle_request t
  ; stop =
      (fun () ->
        t.stopped <- true;
        t.generation <- t.generation + 1;
        end_session t)
  }
;;

let start ?(config = Config.ocamllsp) ~cell_width ~root () =
  Source.create (driver ~config ~cell_width ~root)
;;

(* Functions in Config are part of the effective configuration. Physical equality
   deliberately prefers isolation to guessing that two closures are equivalent. *)
let same_config (a : Config.t) (b : Config.t) =
  String.equal a.source b.source && String.equal a.prog b.prog
  && [%equal: string list] a.args b.args
  && [%equal: string list] a.root_markers b.root_markers
  && Time_ns.Span.equal a.shutdown_grace b.shutdown_grace
  && phys_equal a.applies_to b.applies_to && phys_equal a.language_id b.language_id
;;

let start_workspace ?(config_for_path = Config.for_path) ~cell_width () =
  Source.create (fun ~emit ->
    let pools = ref [] in
    let next_pool_id = ref 0 in
    let resources = String.Table.create () in
    let close resource =
      Option.iter (Hashtbl.find_and_remove resources resource) ~f:(fun (_, driver) ->
        driver.Source.Driver.handle (Document_closed { resource });
        if not (Hashtbl.exists resources ~f:(fun (_, other) -> phys_equal other driver))
        then (
          driver.stop ();
          pools := List.filter !pools ~f:(fun (_, _, other) -> not (phys_equal other driver))))
    in
    let open_document resource generation =
      close resource;
      Option.iter (config_for_path resource) ~f:(fun config ->
        let root = canonical (Config.root config resource) in
        let file = canonical resource in
        if Hashtbl.exists resources ~f:(fun (other_file, _) -> String.equal file other_file)
        then emit (Owned { resource; generation; event = Unavailable
          { source = config.source; root; reason = "another open resource has the same lexical LSP URI" } })
        else (
          let driver = match List.find !pools ~f:(fun (r, c, _) -> String.equal root r && same_config config c) with
            | Some (_, _, driver) -> driver
            | None ->
              incr next_pool_id;
              (* Feedback's running/stopped state is keyed by source, not root.
                 Keep each pool isolated there too, including a newly created pool
                 after its predecessor's last document closes. *)
              let server_config =
                { config with source = sprintf "%s#%d" config.source !next_pool_id }
              in
              let driver = driver ~config:server_config ~cell_width ~root ~emit in
              pools := (root, config, driver) :: !pools;
              driver in
          Hashtbl.set resources ~key:resource ~data:(file, driver);
          driver.handle (Document_opened { resource; generation })))
    in
    { Source.Driver.handle = (fun request -> match request with
        | Document_opened { resource; generation } -> open_document resource generation
        | Document_closed { resource } -> close resource
        | Document_changed { resource; _ } | Document_saved { resource; _ } ->
          Option.iter (Hashtbl.find resources resource) ~f:(fun (_, driver) -> driver.handle request)
        | Restart | Kill -> List.iter !pools ~f:(fun (_, _, driver) -> driver.handle request))
    ; stop = (fun () -> List.iter !pools ~f:(fun (_, _, driver) -> driver.stop ());
        pools := []; Hashtbl.clear resources)
    })
;;
