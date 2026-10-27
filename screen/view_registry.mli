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

(** A file to show in the editor area ({!Outcome.t.open_file}). *)
module Location : sig
  type t =
    { path : string (** Absolute. *)
    ; line : int option
    (** 1-based, at the line's first column; past the end means the last line. *)
    }
  [@@deriving sexp_of, equal]
end

(** What a view may know of the application when it performs an action, besides the
    input controller: read-only, computed when the action is performed (keys, palette,
    answers and signals alike), and lazily, so a view that never looks costs nothing.
    Generic: views decide what it means to them (the VCS view refuses work-tree
    rewrites while a file buffer inside its repository is dirty). *)
module Context : sig
  (** A retained file buffer of the session (not a directory buffer, not one without a
      path). *)
  module File : sig
    type t =
      { path : string (** Absolute and normalized (lexical, as the session keys it). *)
      ; label : string
      (** As the tab strip shows it (shortest disambiguating suffix, unsafe bytes
          escaped): for notices. *)
      ; dirty : bool (** Unsaved changes. *)
      ; missing : bool (** Its backing file is gone (marked missing). *)
      }
    [@@deriving sexp_of, equal]
  end

  type t

  (** [files] runs at most once, when first asked. *)
  val create : (unit -> File.t list) -> t

  (** No files. *)
  val empty : t

  (** In tab order, the active buffer's latest state included. *)
  val files : t -> File.t list

  (** The dirty files within [root] ({!Ches_core.Resource.within}), in tab order. *)
  val dirty_within : t -> root:string -> File.t list
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
    ; open_file : Location.t option
    (** Open (or activate) the file and show it, as a picker does: the active file
        tab replaces an active view tab, focus returns to the editor area (the other
        pane when the view is in the split), and the cursor goes to [line]. A file
        that cannot be opened (missing, a directory) gives the view a notice and
        leaves focus where it was. *)
    ; jobs : Ches_vcs.Job.t list
    (** Background work for the frontend's runner, in submission order
        ([Ui_state.take_vcs_jobs]). The job's events come back to this view as
        {!Signal.t.Job}. A job whose id is still in flight (submitted by any view and
        not yet [Finished]) is not submitted: the view is signalled its
        {!Ches_vcs.Job.never_started} report at once instead. *)
    ; reconcile : string list
    (** Absolute paths (directories or files) whose retained file buffers the
        application reconciles with disk ([Session.reconcile]): clean buffers whose
        file changed are reloaded (cursor and scroll kept), clean ones whose file is
        gone are marked missing, dirty ones are untouched. For a view whose work may
        have rewritten files (a VCS discard: the repository root, once the job has
        finished). Applied right after [controller], from key and signal outcomes
        alike; its feedback goes to the feedback line. *)
    ; ask : 'ask option
    (** A question to ask on a float over the view, applied last; it replaces any
        question still pending. *)
    }

  (** No effect, notice, return, file, jobs, reconciliation or question; [controller]
      unchanged. *)
  val create
    :  ?effect:Ches_tile.Text_view.Effect.t
    -> ?notice:[ `Post of string | `Show of string ]
    -> ?return:bool
    -> ?open_file:Location.t
    -> ?jobs:Ches_vcs.Job.t list
    -> ?reconcile:string list
    -> ?ask:'ask
    -> Ches_app.Controller.t
    -> 'ask t
end

(** What the application tells a view without a key: the view's {!Adapter.t.signal}
    turns each into one of its own actions (or ignores it), which is performed like a
    key's action, focused or not. The outcome of a signalled action is applied
    without moving focus or disturbing the focused view (its prefix and footer
    notice): its [controller], [reconcile] and [jobs] apply; a [`Post] notice goes to
    the feedback line only; [`Show] notices, [effect], [return] and [open_file] are ignored; [ask]
    opens only while the asking view itself is focused, and is otherwise withdrawn
    (nothing runs). A pending question survives a signalled action that asks
    nothing. The view's [fit] follows once per input or batch. *)
module Signal : sig
  type t =
    | Shown
    (** The view has a placement again: after the input that moved it out of
        [Hidden], or after the first input for a view installed placed. Moving
        between [Band], [Tab] and [Split] is not signalled; closing and reopening
        is. *)
    | Saved of string list
    (** The session wrote these files (absolute paths, oldest first; at least one)
        during the last input: one signal for all of an input's saves (e.g. a save
        all). Directory-buffer applies are not included. Every installed view gets
        it, placed or hidden. *)
    | Job of Ches_vcs.Event.t
    (** An event of a job this view submitted ({!Outcome.t.jobs}), in the runner's
        order; nothing after its [Finished]. Delivered placed or hidden. Staleness
        is the view's to decide ({!Ches_vcs.Stamps}). *)
  [@@deriving sexp_of]
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
      -> context:Context.t
      -> rows:int
      -> width:int
      -> 'action
      -> 'state * 'action Ask.t Outcome.t
    ; commands : 'state -> Ches_tile.Local_command.t list
    (** The local commands in this state, for [?] help and the palette. Each one's
        keys must {!interpret} to an action in the state that lists it. *)
    ; signal : 'state -> Signal.t -> 'action option
    (** The action a {!Signal.t} means in this state; [None] ignores it. Views
        without background work return [None]. *)
    ; text_area : 'state -> rows:int -> width:int -> Geometry.Rect.t option
    (** Where open {!text_view} text is drawn within the [width] by [rows] content
        viewport, relative to its top-left corner; [None] is the whole viewport. The
        terminal cursor is the text cursor fitted to this area, so a view that draws
        its text in a part of its content (a diff panel beside lists) says which. *)
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

  (** [placement] defaults to [Hidden]. [opens_in] (default [Band]; not [Hidden]) is
      where {!View_command.t.Focus_view} and {!View_command.t.Toggle_view} show the
      view when it is hidden: [Tab] adds and activates a tab, [Split] replaces the
      split view. *)
  val install
    :  ?placement:Placement.t
    -> ?opens_in:Placement.t
    -> ('state, _) Adapter.t
    -> 'state
    -> t

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

(** Where a hidden view is shown by focusing or toggling it ({!Entry.install});
    [Band] for a view that is not installed. *)
val opens_in : t -> View_id.t -> Placement.t

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

(** The adapter's {!Adapter.t.text_area}; [None] also when not installed. *)
val text_area : t -> View_id.t -> rows:int -> width:int -> Geometry.Rect.t option

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
  -> context:Context.t
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
  -> context:Context.t
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
  -> context:Context.t
  -> rows:int
  -> width:int
  -> t * Ask.Question.t Outcome.t option

(** Drop [id]'s pending question without performing anything. *)
val withdraw : t -> View_id.t -> t

(** Tell [id] a {!Signal.t}, performing the action its adapter names for it. [None]
    when nothing ran (not installed, or the adapter ignored it). A pending question
    is kept unless the outcome asks another. See {!Signal} for how the application
    applies the outcome. *)
val signal
  :  t
  -> View_id.t
  -> Signal.t
  -> controller:Ches_app.Controller.t
  -> context:Context.t
  -> rows:int
  -> width:int
  -> t * Ask.Question.t Outcome.t option

(** Typed access to an installed view's state by its adapter's key. *)
val find : t -> 'state Type_equal.Id.t -> 'state option

(** Update an installed view's state; unchanged when none has [key]. *)
val map : t -> 'state Type_equal.Id.t -> f:('state -> 'state) -> t
