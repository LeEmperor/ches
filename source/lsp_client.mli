(** A language-server client: the {!Source.Driver} that runs a server, such as ocamllsp,
    as a child process and speaks the language-server protocol with it (JSON-RPC over
    the server's stdin and stdout), as Neovim's [vim.lsp] does. The server itself is
    the installed program; this is only Ches's half.

    - A session launches the server in the workspace root, sends [initialize] then
      [initialized], and reports [Started]. A program missing from PATH reports
      [Unavailable] (history only). A server that exits, crashes, fails the handshake, or
      breaks the protocol reports [Stopped], with its last line of stderr in the reason.
    - [Document_changed] opens each document ([didOpen]) once the session is
       initialized, using the newest text. Later edits replace one pending snapshot
       per document and schedule a flush 25 ms after its first edit (continuous
       typing does not postpone it). Diffing and serialization happen only at flush.
       Negotiated Full sends whole text; Incremental sends one encompassing UTF-safe
       replacement against the last sent text, using the negotiated position units.
       Invalid UTF-8 or an unknown position encoding falls back to a full event.
       Absent/None change support sends no changes. Wire versions are monotonic;
       only sent versions enter the bounded revision/text history. [Document_saved]
       flushes first, then sends [didSave] (including text if requested); saves before
       initialization are sent after the newest open. Close/restart/stop cancel timers.
     - [Restart] ends the session and starts a new one, which reopens the newest text.
       [Kill] is ignored. Nothing restarts automatically.
     - [Complete] uses the initialized session's completion capability and negotiated
       encoding. It flushes pending changes first, captures the exact snapshot, and
       emits [Completion] directly (not diagnostic feedback). Requests require the
       current document generation and revision. Close, change, restart, supersession
       and [Cancel_completion] cancel pending work. At most one request per document
       and 32 per server survive, each for at most 10 seconds. Late replies are ignored.
       Results contain at most 512 plain-text items, with at most 128 additional edits
       each; invalid/overlapping edits, snippets and commands are rejected. Completion
       lists retain [isIncomplete]. No resolve or command execution is advertised.
     - [Query] handles hover and declaration/definition-first navigation. It flushes
       changes, checks the exact snapshot and cursor, and emits [Query_result].
       One query per document and 32 per connection survive, with a shared ten-second
       deadline across fallback. [Cancel_query] is exact-token; edit/close/restart
       cancel pending work. Unsupported/unavailable queries fail explicitly.
       See source/NAVIGATION.md for normalization and consumer requirements.
     - Each [publishDiagnostics] becomes a [Diagnostics] snapshot for {!Config.source}:
      an open document under Ches's own resource name and mapped revision; any
      other file unversioned, by its path relative to the working directory (absolute
      when outside it).
    - Stopping (Ches quitting) sends [shutdown] and [exit], killing the server if it is
      still running after {!Config.shutdown_grace}. Async's shutdown waits for that, so
      Ches exiting right after stopping does not cut it short.

    Requests the server makes of the client (progress tokens, configuration, capability
    registration) get empty answers, and any other request "method not found"; the
    server's other notifications and its stderr (beyond the stop reason) are dropped. *)
open! Core
open! Async

module Config : sig
  type t =
    { source : string (** The source name in Ches, like Neovim's client name. *)
    ; prog : string (** Searched for on PATH unless it contains a slash. *)
    ; args : string list
    ; applies_to : string -> bool (** Whether a document, by its path, is served. *)
    ; language_id : string -> string (** The document's [languageId], from its path. *)
    ; root_markers : string list (** For {!Workspace_root.find_nearest}. *)
    ; shutdown_grace : Time_ns.Span.t
    }

  (** [ocamllsp] with no arguments, for [.ml], [.mli], [.mll], and [.mly] files, with
      language ids as nvim-lspconfig sends them ([ocaml], [ocaml.interface],
      [ocaml.ocamllex], [ocaml.menhir]), the owner's Neovim root markers
      ([dune-project], [dune-workspace], [*.opam], [opam], [esy.json], [package.json],
      [.git]), and a 1 s grace. *)
  val ocamllsp : t

  (** Built-in [slang-server] with no arguments, for [.sv], [.svh], [.v], and [.vh] files.
      SystemVerilog files use [systemverilog], Verilog files use [verilog]. The root
      markers are [.slang] and [.git], with a 1 s shutdown grace.
      At selection/start, this exact built-in value resolves its program from
      [SLANG_SERVER] (if set, even empty/invalid), then an executable on [PATH],
      then executable [$HOME/slang-server/build/bin/slang-server], else the bare
      [slang-server] name. Invalid explicit overrides report unavailable without
      fallback. Record copies/custom configs retain their supplied program.
      Resolution preserves the built-in function closures for pool sharing. *)
  val slang_server : t

  (** Selects a built-in server for [path], resolving Slang's program at call time,
      or [None] for unsupported files. *)
  val for_path : string -> t option

  (** Nearest directory containing any [root_markers], else [path]'s directory. *)
  val root : t -> string -> string
end

(** Starts a session for the workspace [root]. [cell_width] must be the width the
    frontend draws with, so that columns land where the editor shows them. *)
val start
  :  ?config:Config.t
  -> cell_width:Ches_core.Cell_layout.Width.t
  -> root:string
  -> unit
  -> Source.t

(** Emits authoritative [Servers] snapshots on attach, detach, restart and lifecycle
    transitions, and in response to [Inspect]. Status is [Starting] until initialization
    succeeds, [Unavailable] when launch fails, and [Stopped] on session termination.
    Inventory resources retain the original editor paths and exclude diagnostics-only
    files. Empty pools disappear, including failed pools after their last close.
    Owns one process per root and effective configuration, and routes document
    diagnostics as [Owned] events. Closing the last resource stops its process.
    Source names have stable pool IDs, so lifecycle state is isolated across pools;
    [Owned] carries the separate document generation.
    Symlink paths remain distinct URIs; a second resource normalizing to an already
    open lexical URI is explicitly reported unavailable. Configuration callbacks
    must reuse equivalent function values to share (closures are compared physically).
     Unversioned diagnostics for an open URI use its current text and ownership,
     including after reopen. They carry no revision or lifetime information: a late
     old-lifetime unversioned message is indistinguishable from fresh output and
     may temporarily replace current findings. Closed-URI tombstones reject output;
     versioned histories and session/document generations remain isolated. *)
val start_workspace
  :  ?config_for_path:(string -> Config.t option)
  -> cell_width:Ches_core.Cell_layout.Width.t
  -> unit
  -> Source.t

(** The protocol's values in Ches's terms; exposed for tests. *)
module Convert : sig
  (** The unit of a position's [character]: UTF-16 unless the server chose another. *)
  type encoding =
    | Utf8
    | Utf16
    | Utf32
  [@@deriving sexp_of]

  (** An absent severity is an error, as in Neovim. *)
  val severity : Lsp.Types.DiagnosticSeverity.t option -> Ches_error.Error.Severity.t

  (** On one line: runs of whitespace, line breaks included, become one space. *)
  val message : string -> string

  (** The one-based display column of [character] in [line]. A position past the line's
      end is the column after it; one inside a code point is that code point's. *)
  val column
    :  cell_width:Ches_core.Cell_layout.Width.t
    -> encoding
    -> line:string
    -> character:int
    -> int
end
