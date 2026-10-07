(** A language-server client: the {!Source.Driver} that runs a server, such as ocamllsp,
    as a child process and speaks the language-server protocol with it (JSON-RPC over
    the server's stdin and stdout), as Neovim's [vim.lsp] does. The server itself is
    the installed program; this is only Ches's half.

    - A session launches the server in the workspace root, sends [initialize] then
      [initialized], and reports [Started]. A program missing from PATH reports
      [Unavailable] (history only). A server that exits, crashes, fails the handshake, or
      breaks the protocol reports [Stopped], with its last line of stderr in the reason.
    - [Document_changed] opens the document ([didOpen]) once the session is
      initialized, then sends each new whole text ([didChange], full sync), versioned
      with Ches's revision. [Document_saved] sends [didSave].
    - [Restart] ends the session and starts a new one, which reopens the newest text.
      [Kill] is ignored. Nothing restarts automatically.
    - Each [publishDiagnostics] becomes a [Diagnostics] snapshot for {!Config.source}:
      the open document under Ches's own resource name and the server's version; any
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
    ; root_markers : string list (** For {!Workspace_root.find_first}, in priority. *)
    ; shutdown_grace : Time_ns.Span.t
    }

  (** [ocamllsp] with no arguments, for [.ml], [.mli], [.mll], and [.mly] files, with
      language ids as nvim-lspconfig sends them ([ocaml], [ocaml.interface],
      [ocaml.ocamllex], [ocaml.menhir]), the owner's Neovim root markers
      ([dune-project], [dune-workspace], [*.opam], [opam], [esy.json], [package.json],
      [.git]), and a 1 s grace. *)
  val ocamllsp : t

  (** [slang-server] with no arguments, for [.sv], [.svh], [.v], and [.vh] files.
      SystemVerilog files use [systemverilog], Verilog files use [verilog]. The root
      markers are [.slang] then [.git], with a 1 s shutdown grace. *)
  val slang_server : t

  (** Selects a built-in server for [path], or [None] for unsupported files. *)
  val for_path : string -> t option

  (** The workspace root for [path]: by [root_markers], else [path]'s directory. *)
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
