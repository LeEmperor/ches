(** The popup ("transient") model: a titled set of switches, toggled with [-] then the
    switch's key, and actions, run with a single key. Running an action builds the
    backend's action from the enabled switches, so the popup needs no knowledge of
    what the switches mean. Phase 5's commit popup ([c] commit, [a] amend, [e]
    extend; [-n] [--no-verify], [-s] [--signoff], [-e] [--allow-empty]) and phase 6's
    push and pull popups are values of this type, built by the backend. Rendering, key
    routing and [Escape] belong to the popup float (phase 5).

    Keys are printable ASCII other than space; ['-'] (the switch prefix), ['q'] (close)
    and ['?'] (help) are reserved. A switch and an action may share a key ([-e] and
    [e] above). *)

open! Core

module Switch : sig
  type t =
    { key : char
    ; flag : string (** What the backend receives, e.g. ["--no-verify"]. Unique. *)
    ; description : string (** e.g. ["Disable hooks"] *)
    ; group : string option
    (** Switches sharing a group exclude each other: enabling one disables the others
        (pull's [--rebase] beside a hypothetical [--ff-only] switch). *)
    }
  [@@deriving sexp, equal]
end

module Action : sig
  type 'a t =
    { key : char
    ; description : string (** e.g. ["Commit"] *)
    ; run : enabled:string list -> 'a
    (** The backend's action, given the enabled switches' flags in declaration
        order. *)
    }
  [@@deriving sexp_of]
end

type 'a t = private
  { title : string
  ; switches : Switch.t list (** In display order. *)
  ; actions : 'a Action.t list (** In display order. *)
  }
[@@deriving sexp_of]

(** Fails on an empty title, a reserved or non-printable key, a key used twice among
    the switches or twice among the actions, an empty or duplicate flag, an empty
    description, or an empty group name. *)
val create
  :  title:string
  -> switches:Switch.t list
  -> actions:'a Action.t list
  -> 'a t Or_error.t

module State : sig
  type t =
    { enabled : string list (** Flags, in switch declaration order. *)
    ; dash : bool (** [-] was pressed: the next key names a switch. *)
    }
  [@@deriving sexp, equal]
end

(** No dash pending, and [enabled] (default none) restricted to the popup's flags;
    within a group only the first given flag stays enabled. For popups that remember
    their switches between openings. *)
val initial : ?enabled:string list -> _ t -> State.t

module Reply : sig
  type 'a t =
    | Updated of State.t (** [-] began a switch, or a switch was toggled. *)
    | Run of 'a (** An action key: the backend action; the popup closes. *)
    | Unbound of
        { state : State.t (** Unchanged except that a pending dash is cleared. *)
        ; key : string (** For a hint: ["x"], or ["-x"] after a dash. *)
        }
  [@@deriving sexp_of]
end

(** One key while the popup is open. After [-], a switch key toggles that switch
    (enabling it disables its group's others); [-] again keeps the dash pending. *)
val press : 'a t -> State.t -> char -> 'a Reply.t

(** [Escape]: clears a pending dash, otherwise closes the popup. *)
val escape : State.t -> [ `Close | `Updated of State.t ]

(** The enabled switches, in declaration order. *)
val enabled : _ t -> State.t -> Switch.t list

(** For [?] help and the palette: every switch as (["-n"], ["Disable hooks
    (--no-verify)"]), then every action as (["c"], ["Commit"]). *)
val help : _ t -> (string * string) list
