(** The command palette's interaction state: the query, the ranked commands matching
    it, and the selected command. Terminal-independent and free of effects: it never
    runs a command, it only says which one to run. Placement, scrolling the visible
    rows, and focus belong to the host that presents it.

    {2 Lifecycle}

    The adapter {!create}s a palette when the user opens it, passing an opaque
    ['token] that names the invoking target (the document view a command will apply
    to). It feeds normalized {!Event.t}s to {!update}, which edits the query and moves
    the selection but cannot execute anything. On Enter it calls {!accept}, which
    returns a {!Request.t} to dispatch exactly once, or why nothing should run. To
    cancel, the adapter discards the palette; its {!token} says where focus returns.

    {2 Selection}

    Selection is by command ID, not row. When the query changes, the selected command
    stays selected if it still matches, and otherwise the best match is selected. With
    no matches nothing is selected. {!Event.Next} and {!Event.Previous} stop at the
    ends of the list.

    {2 Query text}

    The query is a single line of valid UTF-8. Typed and pasted text is sanitized:
    a line break (CR LF, LF, or CR) or a tab becomes a space, other control characters
    (U+0000–U+001F, U+007F–U+009F) are dropped, and malformed UTF-8 becomes U+FFFD.
    Backspace removes the last code point. *)

open! Core

module Event : sig
  type t =
    | Insert of Uchar.t (** A typed character, appended to the query. *)
    | Paste of string (** A whole paste, sanitized and appended at once. *)
    | Backspace
    | Next (** Select the next result, toward the bottom. *)
    | Previous (** Select the previous result, toward the top. *)
  [@@deriving sexp_of]
end

module Request : sig
  (** A command to dispatch, through the same route as its key binding. *)
  type 'token t =
    { token : 'token (** The invoking target, which the command applies to. *)
    ; id : Catalog.Id.t
    ; action : Ches_input.Keymap.Action.t
    }
  [@@deriving sexp_of]
end

module Accept : sig
  type 'token t =
    | Execute of 'token Request.t
    (** Close the palette, restore focus to the target, and dispatch once. *)
    | No_selection (** Nothing matches: do nothing and stay open. *)
    | Target_gone of 'token
    (** The invoking target no longer exists: close without dispatching, and report
        it. Never run the command against another target. *)
    | Unavailable of
        { token : 'token
        ; id : Catalog.Id.t
        }
    (** The selected command cannot run in the target's current context: close
        without dispatching, and report it. *)
  [@@deriving sexp_of]
end

type 'token t

(** An open palette with an empty query, listing the commands available in [context]
    with the first selected. *)
val create : Catalog.t -> Catalog.Context.t -> token:'token -> 'token t

val update : 'token t -> Event.t -> 'token t

(** [accept t ~context] resolves the selection against the target's current
    [context], or [None] if the target no longer exists. *)
val accept : 'token t -> context:Catalog.Context.t option -> 'token Accept.t

val token : 'token t -> 'token
val query : _ t -> string

(** Best first; see {!Catalog.search}. *)
val results : _ t -> Catalog.result list

val selected : _ t -> Catalog.Id.t option
