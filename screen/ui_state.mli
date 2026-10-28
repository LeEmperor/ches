(** All UI-side state, and the transition for one input. No Bonsai types appear here, so
    tests drive it headlessly, exactly as the terminal frontend does.

    The model owns a {!Ches_app.Session.t}, with a cached active controller for presentation,
    per-buffer scroll positions, the layout
    preferences, the scroll position, the shared {!Ches_tile.Host} (focus, capture, and a
    bracketed paste's owner), and the minor views' adapter states. Workspace requests and
    zen suppression are UI state, not editor state. This module is application assembly:
    it installs the problems adapter ({!Problems_tile}), the static demo report
    ({!Report_tile}), and the notification history ({!History_tile}) in a
    {!View_registry}, which every generic path (allocation, focus and leaving, fitting,
    key routing, [?] help, palette local commands) goes through by view id; status
    remains non-focusable. *)

open! Core
open Ches_input

module Message : sig
  type kind =
    | Info
    | Warning (** Keymap notices. *)
    | Error
  [@@deriving sexp_of, equal]

  type t =
    { kind : kind
    ; text : string
    }
  [@@deriving sexp_of, equal]
end

(** Normalized terminal events. The frontend converts what its terminal reports. *)
module Input : sig
  type t =
    | Key of Key.t
    | Paste_start
    | Paste_end
    | Animation_tick of Time_ns.t
     (** A timestamped frontend animation-clock pulse; never reaches the editor. *)
    | Resize (** Reconcile allocation/focus without interpreting editor input. *)
    | Source of Ches_error.Source_event.t
     (** A diagnostic source's message, stamped with its owning buffer's revision.
        Diagnostic lists that arrive during Insert are held (newest per source and
        resource) until Insert ends; started/stopped apply at once. Never reaches the
        editor. *)
    | File_picker_snapshot of Ches_file_picker.Model.Discovery.t
    | File_picker_update of Ches_file_picker.Model.Discovery.Update.t
    | File_preview of Ches_file_preview_model.Model.snapshot
    | File_picker_work of Ches_file_picker.Model.Discovery.request
    | File_picker_accept of Ches_tile.View_id.t Ches_file_picker.Model.Request.t
    | Content_picker_accept of (Ches_tile.View_id.t Ches_content_picker.Model.intent [@sexp.opaque])
       (** One bounded ranking turn, rejected if its run/root no longer matches. *)
    | Line_picker_work of int (** Bounded turn, rejected after close/reopen. *)
    | Content_picker_snapshot of (Ches_content_picker.Model.snapshot [@sexp.opaque])
    | Vcs of Ches_vcs.Event.t
    (** A runner's event for a job a registered view submitted ({!take_vcs_jobs}):
        delivered to that view as {!View_registry.Signal.t.Job}, focused or not, and
        dropped when no view owns the job (unknown, or after its [Finished]).
        Consecutive [Vcs] inputs are one step ({!apply_all}). Never reaches the
        editor. *)
  [@@deriving sexp_of]
end

type t
val file_picker_visible_stamp : t -> (int * int * int) option

val create
  :  ?prefs:Geometry.Prefs.t
  -> ?workspace_prefs:Workspace.Prefs.t
       (** Explicit status layout/visibility overrides [tiles_visible] for status. *)
  -> ?tiles_visible:bool
       (** Show all installed tiles initially; default [true]. [false] starts with
           just the document and compact feedback. *)
  -> ?hotkey_hints:bool (** Tile key hints; default [false]. *)
  -> ?buffer_presentation:View_command.Buffer_presentation.t
        (** Default [Top]; [Status_rows] uses passive status rows when available. *)
  -> ?directory_config:Ches_app.Directory_buffer.Config.t
       (** Protected hidden row identities by default; [Exposed] uses legacy tokens. *)
  -> ?smear_enabled:bool
  -> ?report:Report_tile.Item.t list
       (** Installs the static demo report ([--demo-report]); shown initially. *)
  -> ?source_attached:bool
       (** A diagnostic source runs, so {!take_source_requests} reports to it.
           Default [false]. *)
  -> ?views:View_registry.Entry.t list
       (** Further registered views, after problems, the demo report and history. Their
           ids must be new; their commands are {!View_command.t.Toggle_view},
           {!View_command.t.Focus_view}, {!View_command.t.Place_view} and
           {!View_command.t.Run_view_command}. An entry installed [Tab] is a tab
           (inactive until activated); one installed [Split] is the split view.
           Focusing or toggling a hidden view shows it where it [opens_in]
           ({!View_registry.Entry.install}). *)
  -> Ches_app.Controller.t
  -> t

(** The primary (editor) view and the non-focusable status view. *)
val document_id : Ches_tile.View_id.t
val directory_id : Ches_tile.View_id.t
val side_layout : t -> width:int -> height:int -> Tile_shell.Layout.t option
(** Rendering-only snapshot of a retained surface; never adopt or dispatch it. *)
val surface : t -> directory:bool -> t

val status_id : Ches_tile.View_id.t

(** Active file or directory presentation snapshot. Last-file close normally shows
    the remembered/startup directory. If fallback loading failed, check [has_document]
    before dispatch/rendering; use [session] for ownership. *)
val controller : t -> Ches_app.Controller.t
val session : t -> Ches_app.Session.t
val show_directory : ?select:string -> t -> width:int -> height:int -> string -> t Or_error.t
val has_document : t -> bool
val open_file : t -> width:int -> height:int -> string -> (t * Ches_app.Buffer_id.t) Or_error.t
val activate_buffer : t -> width:int -> height:int -> Ches_app.Buffer_id.t -> t Or_error.t
val close_current : t -> width:int -> height:int -> force:bool -> t * bool
val close_buffer : t -> width:int -> height:int -> Ches_app.Buffer_id.t -> force:bool -> t * bool
val save_all : t -> width:int -> height:int -> t * (Ches_app.Buffer_id.t * bool) list
val quit_session : t -> width:int -> height:int -> force:bool -> t * Ches_app.Controller.Status.t
val prefs : t -> Geometry.Prefs.t
val workspace_prefs : t -> Workspace.Prefs.t
val hotkey_hints : t -> bool
val buffer_presentation : t -> View_command.Buffer_presentation.t
(** Effective placement: false in zen or when status cannot fit/is hidden. *)
val buffers_in_status : t -> width:int -> height:int -> bool
val zen : t -> bool

(** The registered views and their placements. *)
val views : t -> View_registry.t

(** Whether a registered view is placed (requested), even if zen or a small screen
    leaves it without an allocation, or it is an inactive tab. *)
val view_visible : t -> Ches_tile.View_id.t -> bool

(** A view's title (its spec's), for notices. *)
val view_title : t -> Ches_tile.View_id.t -> string

(** A view tab's label in the strip and status: its adapter's
    {!View_registry.Adapter.t.label} in its current state, else its title. *)
val tab_label : t -> Ches_tile.View_id.t -> string

(** The tab strip: the session's file tabs and the views placed [Tab], in order. *)
val tab_entries : t -> Tab_strip.Entry.t list

(** {!tab_entries} as drawn, in the top strip or the status rows: a file's label and
    flags, or a view's {!tab_label}. Exactly one is active when any is: the active view
    tab, else the session's active file. *)
val tab_items : t -> Tab_strip.Item.t list

(** The active view tab, which fills the editor area instead of the active file tab
    (or a major directory) until a file is shown again. *)
val active_tab_view : t -> Ches_tile.View_id.t option

(** The requested side and share of the major split's view. *)
val split : t -> Workspace.Major_split.t

val problems_visible : t -> bool
val problems_current_document : t -> bool
val problems_tile : t -> Problems_tile.t
val report : t -> Report_tile.t option
val report_visible : t -> bool
val history_visible : t -> bool
val history_tile : t -> History_tile.t

(** The command palette, while open (it is then focused). *)
val palette : t -> Palette_tile.t option

(** The [?] help float, while open (it is then focused). *)
val help : t -> Help_tile.t option

(** The open help's centered floating shell; [None] when closed or unfit. *)
val help_layout : t -> width:int -> height:int -> Tile_shell.Layout.t option

(** A registered view's question ({!View_registry.Ask}), asked on the single float
    slot over the view that asked when its outcome carries one: a confirmation, a
    prompt or a popup, while open (it is then focused). The view is not left
    meanwhile. An answer closes the float, refocuses the view (or returns to the
    document when it is gone) and performs the action the view named for it. A
    question that cannot fit is refused with a notice ("<Title> cannot fit; needs at
    least 20 columns and 4 rows; nothing ran"); one whose float loses its room or its
    view, or is left another way (another float, a return to the document), is
    withdrawn with nothing run ("<Title> closed; nothing ran" where it closed
    itself). Leader workspace keys work in all three; paste is rejected except in
    the prompt. *)
val confirm : t -> Confirm_tile.t option

val confirm_layout : t -> width:int -> height:int -> Tile_shell.Layout.t option
val prompt : t -> Prompt_tile.t option
val prompt_layout : t -> width:int -> height:int -> Tile_shell.Layout.t option

(** The popup float ({!Popup_tile}), while open. It is focused, except while [?]
    help covers it ({!help}, whose origin is then {!Popup_tile.id}); closing help
    refocuses the popup with its switches as they were. Help goes with a withdrawn
    popup. *)
val popup : t -> Popup_tile.t option

(** The open popup's centered floating shell; [None] when closed or unfit. Help over
    the popup has its own ({!help_layout}). *)
val popup_layout : t -> width:int -> height:int -> Tile_shell.Layout.t option

(** Provider assembly boundary (also used by the production frontend).
    Only one transient float exists. Refusal calls [release]; all closing paths
    cancel discovery once. Returning restores the prior available capture. *)
val open_file_picker
  : t -> width:int -> height:int
  -> discovery:Ches_file_picker.Model.Discovery.t
  -> release:(unit -> unit) -> t
val can_open_file_picker : t -> width:int -> height:int -> bool
val file_picker : t -> Ches_tile.View_id.t File_picker_tile.t option
val open_content_picker : t -> width:int -> height:int
  -> snapshot:Ches_content_picker.Model.snapshot -> release:(unit -> unit) -> t
val content_picker : t -> Ches_tile.View_id.t Content_picker_tile.t option
val content_picker_layout : t -> width:int -> height:int -> Tile_shell.Layout.t option
val take_content_requests : t -> t * Ches_tile.View_id.t Ches_content_picker.Model.intent list
val file_picker_layout : t -> width:int -> height:int -> Tile_shell.Layout.t option
val open_line_picker : t -> width:int -> height:int -> t
val line_picker : t -> Line_picker_tile.t option
val line_picker_generation : t -> int
val line_picker_layout : t -> width:int -> height:int -> Tile_shell.Layout.t option
(** Take after installing the returned UI state, then deliver to an injected
    consumer. Capture/discovery are already released; intents are not retried. *)
val take_file_requests : t -> t * Ches_tile.View_id.t Ches_file_picker.Model.Request.t list
val take_file_picker_activation : t -> t * bool
val take_content_picker_activation : t -> t * bool
val with_notice : ?source:string -> t -> string -> t

(** The open palette's centered floating shell; [None] when closed or when the
    terminal cannot fit its frame, query row, and one result row. *)
val palette_layout : t -> width:int -> height:int -> Tile_shell.Layout.t option

(** The effective focus: a supporting view only while its layout is available.
    [floating] has the same overriding semantics as {!view_layout}. *)
val focused_view
  :  ?floating:(Ches_tile.View_id.t * Tile_shell.Layout.t option)
  -> t
  -> width:int
  -> height:int
  -> Ches_tile.View_id.t

(** The view supplying the terminal cursor, if any: the document when focused. *)
val cursor_owner
  :  ?floating:(Ches_tile.View_id.t * Tile_shell.Layout.t option)
  -> t
  -> width:int
  -> height:int
  -> Ches_tile.View_id.t option

val problems_focused : t -> width:int -> height:int -> bool

(** The terminal cell and shape of the focused minor view's cursor, when that view owns
    the cursor and its adapter's {!Ches_tile.Cursor} intent lies in its content: a block
    on the text cursor of open read-only text ({!Ches_tile.Text_view}). [None] while the
    document owns the cursor, in a list, for views without text, or for an intent
    outside the content. Exactly one view owns the terminal cursor at a time. *)
val minor_cursor
  :  ?floating:(Ches_tile.View_id.t * Tile_shell.Layout.t option)
  -> t
  -> width:int
  -> height:int
  -> (int * int * Ches_tile.Cursor.Shape.t) option

(** The shared shell layout of an allocated minor view. Rendering and the view's
    content viewport (selection rows, scroll range, detail wrapping) both use it. *)
val minor_layout
  :  t
  -> width:int
  -> height:int
  -> Ches_tile.View_id.t
  -> Tile_shell.Layout.t option

(** Resolve a supporting view's shared shell in either layer. [floating] names
    the transient view and its already computed layout; [None] for that layout
    means it cannot fit, and never falls back to a tiled allocation. Without this
    argument, resolve the live floating palette or tiled status/minor views. The document uses
    {!geometry}, rather than a supporting shell, and returns [None]. This query
    does not change workspace allocation or state. *)
val view_layout
  :  ?floating:(Ches_tile.View_id.t * Tile_shell.Layout.t option)
  -> t
  -> width:int
  -> height:int
  -> Ches_tile.View_id.t
  -> Tile_shell.Layout.t option

(** Availability for {!Ches_tile.Host.focused}, [cursor_owner], and [reconcile].
    The document is always available; supporting views use {!view_layout}. *)
val view_available
  :  ?floating:(Ches_tile.View_id.t * Tile_shell.Layout.t option)
  -> t
  -> width:int
  -> height:int
  -> Ches_tile.View_id.t
  -> bool

val problem_navigation
  :  t
  -> width:int
  -> height:int
  -> Problems.Key.t Ches_tile.Navigation.Selection.t

val selected_problem : t -> width:int -> height:int -> Problems.Row.t option
val problem_details : t -> bool
val problem_detail_top : t -> int

(** The focused view's capture notice and pending prefix, for its footer. *)
val capture_notice : t -> string option

val capture_pending : t -> string option

(** Shared feedback update with selection reconciliation. No editor input or IO. *)
val update_feedback
  : t -> width:int -> height:int -> Ches_error.Error.update -> t

(** Effective workspace allocation. Zen suppresses status without changing requested
    visibility/placement/sizes. Width and height requests are remembered separately.
    Status remains non-focusable. Problems focus is effective only while its
    allocation exists. Resize events persistently restore document focus when hidden. *)
val workspace : t -> width:int -> height:int -> Workspace.t

val scroll : t -> Scroll.t
val message : t -> Message.t option
val animation : t -> Animation.t

(** Whether a bracketed paste is being collected. *)
val pasting : t -> bool

(** The session clipboard queue: what the frontend
    should put on the system clipboard after the inputs it just applied, from an editor
    yank or a copy in a read-only view, whichever was newest. *)
val take_clipboard : t -> t * string option

(** What the frontend should send the diagnostic source after the inputs it just
    applied, in order: actual closes, lifetime-tagged opens and changed text for every
    buffer whose revision changed since the last take, all successful saves, then
    [Space v R]/[Space v K] requests in the order given. Empty unless
    [source_attached]. Paths changed by directory saves are dropped, never sent. The
    synchronous side never waits for the source. *)
val take_source_requests : t -> t * Ches_error.Source_request.t list

(** The jobs registered views submitted ({!View_registry.Outcome.t.jobs}) since the
    last take, in submission order, for the frontend's runner. Take after installing
    the returned UI state, like {!take_source_requests}; the runner's events come back
    as {!Input.t.Vcs}. Each id is unique among the jobs in flight: a view that reuses
    one in flight is answered with its never-started report instead.

    {2 Signals}

    Besides keys, a registered view hears {!View_registry.Signal.t}s, which its
    adapter may turn into actions: [Shown] after the input that gave it a placement
    (from [Hidden], or the first input for a view installed placed); [Saved] after an
    input that saved files or directory edits, with the saved files' paths, then the
    paths the directory saves changed ({!Ches_app.Session.directory_changes}) (every
    view, placed or hidden; saves made by {!save_all} or {!quit_session} count at the
    next input); and [Job] for its jobs' events. A signalled action never moves
    focus; see {!View_registry.Signal} for how its outcome applies. *)
val take_vcs_jobs : t -> t * Ches_vcs.Job.t list

(** Whether an input has returned [Exit]. From then on, {!apply} ignores its input and
    returns [Exit] again, so keys that arrive before the frontend has shut down (say,
    [Space w] typed right after [Space Q]) never run. *)
val exited : t -> bool

(** The visible cursor's terminal-cell coordinate, after applying layout and scroll.
    During a block insert it is at the first of [Editor.block_insert_points], which can be
    inside a TAB or past the line's end before anything is typed; the scroll keeps that
    cell in view. {!Frame} then hides the terminal cursor and draws every point as a
    styled cell instead; this position still drives the smear. *)
val cursor_position : t -> width:int -> height:int -> (int * int) option

(** Applies one input on a [width] x [height] screen.

    Keys between [Paste_start] and [Paste_end] are collected with [Key.text] and delivered
    as one paste at the end; keys without text are dropped. Document input goes to the
    controller, with its effects (such as saving) performed before this returns. View
    commands the controller returns update {!prefs} (see {!apply_view}) or, for [Scroll],
    the scroll.

    {2 Minor view capture}

    Routing for a focused registered view is {!View_registry.key}, through
    {!Ches_tile.Host.key}; the focused view's adapter performs its content actions. The problems bindings below are the
    problems adapter's; the demo report ([Space v d] shows/hides, [Space v D]
    focuses/returns) uses the same host with [j/k], [gg/G], [Ctrl-d/u], and [e]/Enter
    for details. So does the notification history ([Space v m] shows/hides,
    [Space v M] focuses/returns), where [X] also clears the history (never active
    problems) through [Clear_history].

    Normal [Space v o] shows/focuses problems, or returns to the editor. Entry and
    return cancel pending editor input. Existing Normal prefixes/counts/search retain
    keymap precedence; focus does not intercept an incomplete editor command.
    In problems, [j/k], [gg/G], [Ctrl-d/u] select/scroll; [e] toggles wrapped details
    (movement then scrolls details), [a] acknowledges the selected identity without
    resolving it, and Enter performs a validated current-file jump and returns.
    Escape cancels a pane prefix, then closes details, then returns without
    acknowledgement. Tab returns directly. [Space v] uses configured view bindings;
    editor commands and document scrolling are rejected during capture.
    Hiding/zen/undersized allocations restore document focus and clear pane prefixes.
    Bracketed paste retains its start owner; a paste started in a read-only view is
    rejected even after resize.
    Selection follows identity; removal/filtering chooses the previous index's next
    neighbor, falling back to the last item. An empty list retains pane focus until
    explicitly returned/hidden. No editor smear is drawn in capture.

    {2 View tabs and the major split}

    A registered view has one placement ({!View_registry.Placement.t}): hidden, the
    bottom band, a tab, or the split. [Place_view] moves it ([Space s t/s/b/h] move
    the focused view to a tab, the split, the band, or close it); [Toggle_view]
    shows a hidden view where it opens (the band unless installed otherwise, see
    {!View_registry.Entry.install}) and closes it from any placement.

    A view tab is added after the active entry and activated. While active it fills
    the editor area below the strip and is the editor area's input owner: returning
    from a captured view (Escape, Tab, closing a float) comes back to it, and the
    hidden document never has focus. [Space b n/p] cycle file and view tabs
    together. [Space b c]/[Space b C] on an active view tab close the view (through
    the registry: hidden, then left), showing the active file tab, whose dirty checks
    are unaffected. [Focus_view] activates a view tab, and on the focused active tab
    shows the active file tab instead. Showing a file also leaves the view tab:
    activating or opening one (tabs, pickers, a directory entry, a problem jump), a
    major directory, or [Space o] back from a directory.

    The split view shares the editor area beside the active tab (file or view),
    side by side, separated by a gap: [Space s f] focuses the other pane, [Space s x]
    swaps sides, [Space s +]/[Space s -] change its share by 10% (20%..80%), and
    [Space s c] closes it from either pane, even while it is not shown. Placing
    a view there closes the previous split view and focuses the new one. It is not
    allocated in zen, or when the editor area (after a side directory and status)
    cannot keep {!Workspace.min_document_width} beside {!Workspace.min_split_width};
    it then stays in the split placement, a resize saying when it is hidden and
    restored.

    A view's outcome may open a file ({!View_registry.Outcome.t.open_file}): as a
    picker would, the file tab replaces an active view tab and focus returns to the
    editor area, which beside a split view is the other pane. With
    [Location.contents] the file is written first (refused while its buffer is
    dirty; a retained clean buffer is reloaded). It may save retained buffers before
    its jobs run ({!View_registry.Outcome.t.save}) and dispose of files it handed out
    ({!View_registry.Outcome.t.dispose}): their buffers closed, the files deleted,
    and, when the user was in one, focus given to the view where it is placed.

    [Request_view] ([Space g c], [Space g a]) signals a named request to a view,
    focused or not ({!View_registry.Signal.t.Request}); a view that is not installed
    gives its notice, one that ignores the request says ["<Title>: nothing to do for
    <request>"], on the feedback line (and in the focused view's or float's footer).

    It may ask for open-buffer reconciliation ({!View_registry.Outcome.t.reconcile}),
    from a key or a signal: the session rereads the retained file buffers within
    those paths at once ([Session.reconcile]), and the result is adopted without
    moving focus or leaving a view tab (buffer ids, hence scrolls, are unchanged).
    Every action the view performs gets a {!View_registry.Context.t} built from the
    session with the active buffer's latest state.

    [Place_view] without a view ([Space s t/s/b/h]) typed in help, a question or a
    popup over a view moves that view.

    {2 View-local commands and help}

    A registered view declares local commands for its current state
    ({!View_registry.Adapter.t.commands}). [?], when the view's own keys leave it
    unbound, opens a read-only help float listing them over the view, which is not
    left; [j/k], [gg/G] and [Ctrl-d/u] scroll it, and [q], [?], Escape or Tab return
    to the view. [?] in the editor (backward search) and in text-input floats (query
    text) is unchanged. The command palette opened over a registered view (or its
    help) lists that view's commands first, titled [<Title>: <description>] with
    their keys as shortcuts, and does not leave the view; accepting one closes the
    palette, refocuses the view and runs it as its keys would
    ({!View_command.t.Run_view_command}). Any other command, or closing, returns to
    the document as before.

    {2 Read-only text in minor views}

    Open details (problems, the demo report, and history) are read-only text
    ({!Ches_tile.Text_view}): a text cursor, which is then the terminal cursor (see
    {!minor_cursor}), movement, [v]/[V] Visual selection, and [y]/[yy]/[Y] copies; in a
    list, [yy]/[Y] copy the selected item's whole text. Escape ends Visual before it
    closes details. A copy goes to the editor's unnamed register and the system
    clipboard ({!Ches_app.Controller.yank}, then {!take_clipboard}) and shows
    [Copied ...] in the view's footer; it runs no editor command and never inspects,
    acknowledges, or jumps. Edit keys give [<Title>: read-only; edits unavailable].
    When a problem's text changes while its details are open, the view takes the new
    text and says [Details updated], adding [; selection cleared] if Visual ended.

    {2 Scrolling}

    Scroll commands work on the text viewport's rows and change nothing when it has none.
    The first visible line stays within the document, so [Line_down] ([Ctrl-e]) can scroll
    until the last line is at the top. When a scroll would take the cursor line out of
    view, the cursor is moved to the nearest visible line with a counted [Up]/[Down]
    through {!Ches_app.Controller.move}, keeping its preferred column. This is the one
    view command that touches the editor: it moves the cursor only, never text, history,
    or dirty state.

    - [Line_down]/[Line_up] scroll by one line or the count.
    - [Half_page_down]/[Half_page_up] scroll and move the cursor by half the rows (at
      least 1), or the count. Scrolling down stops once the last line is at the bottom (or
      stays, if scrolled further already); the cursor still moves, so a repeat reaches the
      last line. At the top, only the cursor moves.
    - [Cursor_top]/[Cursor_middle]/[Cursor_bottom] put the cursor line at the top, middle
      (row [(rows - 1) / 2]), or bottom, without moving the cursor; the first line is not
      lowered below the document start.

    {2 Messages}

    Status presentations query the controller's shared feedback. A dispatched editor
    command clears transient feedback; prefixes, ignored input, animation, and layout
    actions do not. Layout feedback and keymap notices post new transient notifications;
    only keymap notices are also kept in history, as are editor messages. A view's own
    notices (rejected paste or edit, failed jump) are not.
    Active save/reload problems remain until matching recovery. Idle Normal Escape
    acknowledges the currently presented problem; cancellation and mode exits take
    precedence. [Space v e] cycles retained details without retrying or renewing
    attention. Acknowledged problems remain visible as a compact count until recovery.

    Status commands in zen update saved requests without leaving zen. Document reset
    leaves workspace intent alone.

    Animation ticks change only animation and its clock when dimensions match the
    last fit/resize; they do not synchronize mutable pickers or refit panes/scroll.
    A tick at new dimensions still reconciles and fits the workspace.
    The scroll is then fitted to keep the cursor visible (see {!fitted_scroll}). Once an
    input returns [Exit], no later input is applied (see {!exited}). *)
val apply : t -> width:int -> height:int -> Input.t -> t * Ches_app.Controller.Status.t

(** The requested preferences after a view command; [Scroll] leaves them unchanged.
    [Shift] and [Adjust_width] also select centered mode, so their effect is visible. The
    requested width is kept within {!min_width}..{!max_width} and the offset within
    [-max_offset..max_offset]; the screen may show less (see {!Geometry.compute}), and the
    request is kept for when it grows. *)
val apply_view : Geometry.Prefs.t -> View_command.t -> Geometry.Prefs.t

val min_width : int
val max_width : int
val max_offset : int

(** [apply] for each input in order, stopping at [Exit]. Consecutive [Source] inputs
    (a frontend's batch of source events) are applied as one step that synchronizes the
     views once, with the same result; so are consecutive [Vcs] inputs. [after_step] installs frontend-owned picker
     activation before the next input, so batched query keys retain their owner. *)
val apply_all
   :  ?after_step:(t -> t)
   -> t
  -> width:int
  -> height:int
  -> Input.t list
  -> t * Ches_app.Controller.Status.t

(** Document geometry within the effective workspace on a [width] x [height] screen. *)
val geometry : t -> width:int -> height:int -> Geometry.t

(** {!scroll} fitted to a [width] x [height] screen, so a resize keeps the cursor visible
    before the next input arrives. The fit fills the viewport (lowering the first line so
    it is not partly empty while earlier lines are hidden) only when the number of text
    rows differs from the last applied input's, that is, after a resize; otherwise a view
    scrolled past the end stays put (see {!Scroll.fit}). *)
val fitted_scroll : t -> width:int -> height:int -> Scroll.t

(** Explicit-allocation counterparts of the workspace queries above. All three use the
    same allocation and explicit status policy; scroll positions remain document
    coordinates and cursor positions are terminal coordinates. These queries do not change
    the model or editor. *)
(** Tab strip above the document; a single entry, zen and tiny allocations hide it.
    Explicit allocations have no status tile by default. Assembly passes the same
    effective [buffers_in_status] to all queries when a status tile is present. *)
val tab_rect : ?buffers_in_status:bool -> t -> allocation:Geometry.Rect.t -> Geometry.Rect.t option
val directory_rect : ?buffers_in_status:bool -> t -> allocation:Geometry.Rect.t -> Geometry.Rect.t option
val geometry_in : ?buffers_in_status:bool -> t -> allocation:Geometry.Rect.t -> reserve_status_row:bool -> Geometry.t

val fitted_scroll_in
  :  ?buffers_in_status:bool
  -> t
  -> allocation:Geometry.Rect.t
  -> reserve_status_row:bool
  -> Scroll.t

val cursor_position_in
  :  ?buffers_in_status:bool
  -> t
  -> allocation:Geometry.Rect.t
  -> reserve_status_row:bool
  -> (int * int) option
