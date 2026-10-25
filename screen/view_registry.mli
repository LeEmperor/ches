(** The installed views that {!Ui_state} hosts beside the document, each an adapter
    with its own state. Generic code (allocation, focus, leaving, fitting, key routing,
    rendering, help, and the palette's local commands) goes through this registry, so
    installing a view needs no per-name branch in [Ui_state] or [Frame]. Floats (the
    palette and pickers) and the directory are not registered views.

    A view is registered in one of two forms: installed, with an adapter, its state and
    a {!Placement.t}; or unavailable, with only an id, a title and the notice that
    commands naming it report (the demo report without [--demo-report]). Order is
    significant: placed views are allocated in registry order. *)

open! Core
open Ches_input
module View_id = Ches_tile.View_id

(** Where an installed view is shown: exactly one placement at a time. Placement is
    the registry's, not the adapter's: hiding never discards the view's state.
    [Band] views are allocated in the workspace's bottom band ({!Workspace.allocate})
    in registry order; [Tab] views are ordered by the {!Tab_strip}; the [Split] view
    (at most one) is the major split's peer pane. *)
module Placement : sig
  type t = View_command.Placement.t =
    | Hidden
    | Band
    | Tab
    | Split
  [@@deriving sexp_of, equal]
end

(** A question a view asks the user on a float over itself, and the view's own action
    that each answer performs. A confirmation's default answer is No: only [y]
    performs [yes]. A prompt's [accept] runs only on text that [validate] passes
    ([None]; [Some error] is shown inline). [no] and [cancel] are performed when the
    user declines; a question withdrawn without an answer (its float cannot fit, the
    view is left or hidden) performs nothing. *)
module Ask : sig
  type 'action t =
    | Confirm of
        { title : string
        ; message : string
        ; yes : 'action
        ; no : 'action option
        }
    | Prompt of
        { title : string
        ; initial : string
        ; validate : string -> string option
        ; accept : string -> 'action
        ; cancel : 'action option
        }

  (** The question alone, as the application shows it. *)
  module Question : sig
    type t =
      | Confirm of
          { title : string
          ; message : string
          }
      | Prompt of
          { title : string
          ; initial : string
          ; validate : string -> string option
          }
  end

  val question : _ t -> Question.t
end

(** The user's answer to a view's pending question ({!answer}). [Yes] answers only a
    confirmation and [Text] only a prompt; any other answer declines. *)
module Answer : sig
  type t =
    | Yes
    | No
    | Text of string
  [@@deriving sexp_of, equal]
end

(** What performing an action asks of the application, besides the view's new
    state. An adapter's ['ask] is an {!Ask.t} of its own actions; the application
    receives only its {!Ask.Question.t}. *)
module Outcome : sig
  type 'ask t =
    { controller : Ches_app.Controller.t (** The input controller, or a changed one. *)
    ; effect : Ches_tile.Text_view.Effect.t option (** A copy or read-only notice. *)
    ; notice : [ `Post of string | `Show of string ] option
    (** [`Post] also reports the notice as feedback; [`Show] only displays it. *)
    ; return : bool (** Return focus to the document afterwards. *)
    ; ask : 'ask option
    (** A question to ask on a float over the view, applied last; it replaces any
        question still pending. *)
    }

  (** No effect, notice, return, or question; [controller] unchanged. *)
  val create
    :  ?effect:Ches_tile.Text_view.Effect.t
    -> ?notice:[ `Post of string | `Show of string ]
    -> ?return:bool
    -> ?ask:'ask
    -> Ches_app.Controller.t
    -> 'ask t
end

module Adapter : sig
  (** A view's callbacks over its own ['state]; ['action] is what its keys mean.
      [rows] and [width] are always the view's content viewport in its placement (one
      row and the screen width while it has none). *)
  type ('state, 'action) t =
    { spec : Ches_tile.Spec.t (** Identity, title (for notices), and capabilities. *)
    ; key : 'state Type_equal.Id.t (** Typed access for the application ({!find}). *)
    ; fit : 'state -> Ches_app.Controller.t -> rows:int -> width:int -> 'state
    (** Reconcile with the application and the viewport, after every input. *)
    ; leave : 'state -> 'state
    (** Close capture-local state (details, Visual) when focus leaves the view. *)
    ; text_view : 'state -> Ches_tile.Text_view.t option
    (** Open read-only text: the terminal cursor's position, and the shared
        [Details updated] notice when a fit changes its text. *)
    ; interpret : 'state -> Key.t list -> 'action Ches_tile.Content_key.t
    ; escape : 'state -> 'action option (** The content's own back action. *)
    ; hint : string (** For an unbound key. *)
    ; perform
      :  'state
      -> Ches_app.Controller.t
      -> rows:int
      -> width:int
      -> 'action
      -> 'state * 'action Ask.t Outcome.t
    ; commands : 'state -> Ches_tile.Local_command.t list
    (** The local commands in this state, for [?] help and the palette. Each one's
        keys must {!interpret} to an action in the state that lists it. *)
    ; render
      :  'state
      -> Ches_app.Controller.t
      -> hotkey_hints:bool
      -> focused:bool
      -> notice:string option
      -> pending:string option
      -> width:int
      -> rows:int
      -> Tile_shell.Content.t
    }
end

module Entry : sig
  type t

  (** [placement] defaults to [Hidden]. *)
  val install : ?placement:Placement.t -> ('state, _) Adapter.t -> 'state -> t

  (** A view that is known by id but not installed in this session. *)
  val unavailable : View_id.t -> title:string -> notice:string -> t
end

type t

(** Raises on duplicate ids. *)
val create : Entry.t list -> t

(** Installed views' specs, for {!Ches_tile.Host.create}. *)
val specs : t -> Ches_tile.Spec.t list

(** Installed views, in order. *)
val ids : t -> View_id.t list

val installed : t -> View_id.t -> bool

(** For an unavailable entry: its notice. *)
val unavailable_notice : t -> View_id.t -> string option

(** Installed views and their placements, in order. *)
val placements : t -> (View_id.t * Placement.t) list

val placement : t -> View_id.t -> Placement.t option

(** Installed views placed in the bottom band, in order. *)
val band : t -> View_id.t list

(** Installed views placed as tabs, in registry order. *)
val tabs : t -> View_id.t list

(** The installed view placed in the split, if any. *)
val split : t -> View_id.t option

(** Ignored for a view that is not installed. Placing a view in [Split] closes
    ({!close}) the view that was there. *)
val set_placement : t -> View_id.t -> Placement.t -> t

(** Also withdraws any pending question. *)
val leave : t -> View_id.t -> t

(** Hide the view and {!leave} it: how every placement closes a view. *)
val close : t -> View_id.t -> t

(** Fit every installed view, hidden ones included; [viewport id] is its
    [(rows, width)]. *)
val fit : t -> Ches_app.Controller.t -> viewport:(View_id.t -> int * int) -> t

val text_view : t -> View_id.t -> Ches_tile.Text_view.t option
val commands : t -> View_id.t -> Ches_tile.Local_command.t list

val render
  :  t
  -> View_id.t
  -> Ches_app.Controller.t
  -> hotkey_hints:bool
  -> focused:bool
  -> notice:string option
  -> pending:string option
  -> width:int
  -> rows:int
  -> Tile_shell.Content.t option

(** What a key typed into a focused installed view came to. *)
module Step : sig
  type t =
    | Handled (** Only the host's prefix or notice changed. *)
    | Return
    | Notice of string (** Rejected by the host; the prefix is cancelled. *)
    | Workspace of View_command.t
    | Help
    (** [?], which the view's own keys leave unbound: open its local-command help. *)
    | Performed of Ask.Question.t Outcome.t
    (** The view's state is already updated, and any question is pending. *)
end

(** Route [key] through {!Ches_tile.Host.key} with the view's interpretation, then
    perform any content action. [None] when [id] is not installed. *)
val key
  :  t
  -> View_id.t
  -> Ches_tile.Host.t
  -> Key.t
  -> lookup:(Key.t list -> Bindings.lookup)
  -> controller:Ches_app.Controller.t
  -> rows:int
  -> width:int
  -> (t * Ches_tile.Host.t * Step.t) option

(** Run a local command by name, exactly as its keys would. An error when the view
    is not installed or does not declare the command in its current state. *)
val run
  :  t
  -> View_id.t
  -> string
  -> controller:Ches_app.Controller.t
  -> rows:int
  -> width:int
  -> (t * Ask.Question.t Outcome.t) Or_error.t

(** The question [id] asked in its last outcome and has not had answered. *)
val asking : t -> View_id.t -> Ask.Question.t option

(** Answer [id]'s pending question, performing the action its answer names. [None]
    when nothing ran: no question was pending, declining named no action, or the
    text fails the prompt's validation (the question then stays pending). Otherwise
    the question is answered, and the outcome may ask another. *)
val answer
  :  t
  -> View_id.t
  -> Answer.t
  -> controller:Ches_app.Controller.t
  -> rows:int
  -> width:int
  -> t * Ask.Question.t Outcome.t option

(** Drop [id]'s pending question without performing anything. *)
val withdraw : t -> View_id.t -> t

(** Typed access to an installed view's state by its adapter's key. *)
val find : t -> 'state Type_equal.Id.t -> 'state option

(** Update an installed view's state; unchanged when none has [key]. *)
val map : t -> 'state Type_equal.Id.t -> f:('state -> 'state) -> t
