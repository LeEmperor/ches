(** The VCS view (phase 2: read-only; phase 3: stage, unstage, discard), a registered view ({!View_registry}) over the
    git backend ([Ches_vcs_git.Backend], a {!Ches_vcs.Backend.S}). Lazygit's layout
    and Magit's context keys: the Files, Branches and Commits list panels beside a diff
    panel that follows the selection, a head summary above the lists, and a
    toggleable command log. Nothing runs here: the view hands its work out as
    {!Ches_vcs.Job.t}s in its outcomes ({!View_registry.Outcome.t.jobs}) and hears
    their events as {!View_registry.Signal.t.Job}; the frontend's runner
    ([Ches_ui.Vcs_host]) executes them. It never touches [Ui_state] by name.

    {2 Identity and placement}

    Id ["vcs"] (bindings and the palette, in libraries that cannot see this one, name
    it with [View_id.of_string "vcs"]). Spec: {!Ches_tile.Spec.read_only_text} with
    role [Major] and [accepts_tab = true] (Tab is the view's list/diff switch, so it
    does not return; [q] and Escape leave). Title ["VCS"]: notices ("VCS in tab
    strip", "VCS closed") and the tab label, which is static. The frame title is the
    state's (see {!render}). {!entry} installs it hidden, opening in a tab: focusing a
    hidden VCS view ([Space g g]) adds and activates a tab.

    {2 Lifecycle and work}

    Created with the directory to look for a repository from ([cwd], absolute: the
    startup file's directory or the directory opened). Hidden and never shown, it
    runs nothing. Each time it is shown ({!View_registry.Signal.t.Shown}) it starts
    a new generation ({!Ches_vcs.Stamps.invalidate}: everything in flight becomes
    stale) and detects the repository, then refreshes; the previous snapshot stays
    drawn until the new one arrives. Jobs, by lane (all [Read]):
    - ["detect"]: [Backend.detect ~cwd]; its report goes to [Backend.detected].
    - ["refresh"]: [Backend.refresh repo Refresh.default]; the report goes to
      [Backend.snapshot]. On success the panels are rebuilt, each cursor reconciled
      ({!Ches_vcs.Panel.Cursor.reconcile}, the selection rule), and the diff refetched.
    - ["diff"]: [Backend.diff repo target] for the diff target of the list selection
      ([Backend.diff_target]), whenever that target changes and after every refresh;
      parsed with [Diff.Limits.default]. A [None] target shows "No diff for this row".
    Refresh triggers: shown, [g r], and a [Saved] signal naming a file under the
    repository root (or under [cwd]; session paths are not symlink-resolved), at most
    one refresh per signal. Not found: [g r] detects again; saves are ignored. Reports
    that {!Ches_vcs.Stamps.accepts} rejects only reach the command log; cancelled
    reports change nothing but the log. Failures never raise: a failed detection or
    refresh is shown in the view (the last snapshot kept), a failed diff in the diff
    panel, each with its one-line message, and logged.

    {2 Actions (phase 3)}

    [s] [u] [x] stage, unstage and discard; [S] [U] stage all and unstage all. In the
    Files panel they act on the selected row: an item is
    [Target.File { section; path = key }], a section header [Target.Section]. In the
    diff (while its diff is [Loaded] and not in Visual) they act on the line at the
    cursor ({!Vcs_diff_text.position_at}): on a hunk's [@@] line or one of its lines,
    [Target.Hunk { section; file; hunk; selection = Whole }] with
    [section = Git.Backend.diff_section target] and [file] the [Loaded] diff's file;
    on a file's header lines (or a header-only file's note), [Target.File] of that
    file ({!Ches_vcs.Diff.File.path}) in that section. A commit's diff, the preamble,
    notes outside any file, a loading or failed diff, give a [`Show] notice ("Nothing
    to stage here: a commit's diff", "No change at the cursor", "The diff is still
    loading") and run nothing; in Visual, ["Staging selected lines is not supported
    yet; nothing ran"] (phase 4 replaces it). [S] and [U] work from the Files panel
    and the diff. The Branches and Commits panels leave all five unbound.

    The action goes to the backend's [plan] (the [?plan] given to {!create}, by
    default [Git.Backend.plan]) with the current repository and snapshot:
    - [Refused message]: a [`Show] notice; nothing runs.
    - A plan with [rewrites_worktree] (every discard) while any file buffer within
      the repository root is dirty ({!View_registry.Context.dirty_within}, from the
      perform context) is refused before any question: [`Post] ["<plan title>
      refused: unsaved changes in <label>, <label>; save or undo them first; nothing
      ran"], labels as the tab strip shows them, in tab order.
    - [Confirm { title; message; plan }]: an {!View_registry.Ask.t.Confirm} with that
      title and message (the default answer is No; only [y] confirms), [yes] running
      the plan and [no = None]. On [y] the dirty check runs again (the answer's
      context) before anything runs.
    - [Run plan], or a confirmed plan: its steps go out as one [Mutate] job (no
      lane; an id from the view's stamps), submitted through
      {!View_registry.Outcome.t.jobs}; the runner serializes it with every other
      mutation. When the action stages ([Stage], [Stage_all]) and a dirty file
      buffer's path is among the paths it stages (a [File]'s key, a [Hunk]'s file
      path, a [Section]'s or [Stage_all]'s keys from the Files panel; a key ending in
      ["/"] covers the paths under it), the outcome also posts [`Post] ["<label>,
      <label> have unsaved changes: the saved files were staged, not the buffers"]
      ("<label> has ..." for one): a warning, it still runs.
    - While a mutation of this view is in flight or the refresh that follows it has
      not been applied ({!mutation}), [s u x S U] give the [`Show] notice ["Busy:
      <title>; nothing ran"] instead of planning.
    When the mutation's [Finished] report arrives (signalled; current or stale,
    cancelled or not): every [Run] step is logged as refresh commands are (the
    command, its status, a failed step's stderr tail; [--check] steps included);
    a failure ({!Ches_vcs.Job.Report.first_failure}) posts [`Post] ["<title> failed:
    <one-line failure>"] (feedback only, as for any signalled outcome), a success
    posts nothing; a plan with [rewrites_worktree] asks the application to reconcile
    open buffers within the root ({!View_registry.Outcome.t.reconcile} [= [root]]),
    whatever the outcome (a failed step may have rewritten some files); and a refresh
    follows when the report is of the current generation (a stale one was overtaken
    by a newer detection, which refreshes anyway). {!mutation} clears when that
    refresh's snapshot is applied (or fails).

    Selection after an action: the refresh reconciles each cursor
    ({!Ches_vcs.Panel.Cursor.reconcile}): an item still listed stays selected; one
    that left its section (staged, discarded) gives way to the next item of that
    section, else the previous, else the section's header, else the nearest
    section's header. Focus stays where it was.

    The diff cursor after a hunk action: the view remembers the target, the file's
    path and the hunk's index. When the next [Loaded] diff for the same target
    arrives, the cursor goes to the [@@] line of the hunk with that index in that
    file (the next hunk now that the acted one left), else the file's last hunk, else
    its first line, else the first line ({!Ches_tile.Text_view.jump}). A different target (the
    file left the section and the selection moved) starts at the top as any new
    selection does.

    Also in the diff: [\]] and [\[] move the cursor to the next and previous [@@]
    line ({!Vcs_diff_text.hunk_starts}); nothing beyond the last or first.

    Local commands (help and palette) in the states where they work: [stage] ([s]),
    [unstage] ([u]), [discard] ([x]), [stage-all] ([S]), [unstage-all] ([U]) in the
    Files panel and the diff while a snapshot is loaded; [next-hunk] ([\]]) and
    [previous-hunk] ([\[]) in the diff. The hint mentions [s u x].

    {2 Layout}

    {!Layout.compute} divides the content viewport (the view's own rows and width
    in its placement) into the lists column (head summary, then the list panels),
    the diff panel and the command log. Wide: side by side. Narrow (a split, a small
    terminal) but tall: stacked, lists above the diff. Below that: only the focused
    part (the lists when a list panel is focused, the diff when the diff is). The log,
    when toggled on and the viewport is tall enough, takes the bottom rows across the
    full width.

    {2 Keys} (the read-only subset of the plan's table; every key below is a local
    command for [?] help and the palette, in the states where it works)

    Whole view:
    - [1] [2] [3], from a list panel: focus the Files, Branches, Commits panel
      ([focus-files], [focus-branches], [focus-commits]). In the diff, digits are
      the text's count instead (below).
    - [0], from a list panel: focus the diff ([focus-diff]); [Tab]: from a list
      panel to the diff, from the diff back to the list panel it follows
      ([toggle-diff]).
    - [g r]: refresh, or detect again when no repository was found ([refresh]).
    - [@]: show or hide the command log ([toggle-log]).
    - [q]: leave the view ([leave]): {!View_registry.Outcome.t.return}, so a tab
      gives way to the active file tab and a split view gives focus to the editor
      pane. Escape: in the diff, ends Visual, then goes back to the list panel; in a
      list panel, the host's return (which stays in an active view tab).
    - [?]: unbound, so the host opens the help float.
    List panels:
    - [j] [k] [g g] [G] [Ctrl-d] [Ctrl-u]: move over the visible rows (section
      headers and items; {!Ches_tile.Navigation.commands}); the diff follows.
    - Enter: on a section header, fold or unfold it
      ({!Ches_vcs.Panel.Cursor.toggle_fold}); on a Files or Commits item, focus the
      diff ([select]). On a branch it is unbound (checkout arrives in phase 6), so
      [select] is not listed there.
    - [y]: copy the selected item's name: a file's path, a branch name, a commit's
      abbreviated hash (7 characters) ([copy]); nothing on a header.
    Diff panel:
    - The read-only text keys ({!Ches_tile.Text_view.commands}: [j k w b 0 $ g g G
      Ctrl-d Ctrl-u v V y] ...), with counts: [10j], [3 Ctrl-d], [12G]. Every digit
      goes to the text: [0] is its line start (or extends a count), not
      [focus-diff], and [1] [2] [3] start a count rather than switching panels;
      [Tab] or Escape returns to the lists first.
    - [e], Enter: open the file at the cursor's line ([open-file]), see below.

    In the not-a-repository and failed states only [g r], [@], [q], [?] and the
    panel keys that make sense with nothing loaded work; the hint names them.

    {2 Opening a file from the diff}

    [e]/Enter in the diff returns {!View_registry.Outcome.t.open_file} with the
    absolute path ([root] ^ "/" ^ the file's {!Ches_vcs.Diff.File.path}) and a line:
    on an [Added] or [Context] line its [new_line]; on a [Removed] line the
    [new_line] of the next line in its hunk that has one, else the hunk's
    [new_start]; on a hunk header its [new_start]; on a file header or the preamble,
    no line (the file's first line). A deleted file ([new_path = None]) or a cursor
    outside any file gives a [`Show] notice instead and opens nothing. A commit's
    diff opens the work-tree file at the commit's line numbers (it may have changed
    since). [Ui_state] does the rest: the file tab replaces the VCS tab, or, beside
    a VCS split view, the file shows in the other pane, which is focused.

    {2 Rendering}

    Text from git (paths, subjects, output lines) is raw bytes: control bytes are
    escaped for display, never drawn. Diff lines use {!Style.Diff_added},
    {!Style.Diff_removed}, {!Style.Diff_hunk} and {!Style.Diff_meta}; binary,
    submodule, mode-only and rename-only files render as their headers (see
    {!Ches_vcs.Diff.File.line_actions}); an [Unmerged] file shows its combined hunks
    (the conflict markers, openable at their result line) when git gives them, else
    its ["* Unmerged path"] header; a truncated file ends with a
    placeholder naming the omitted hunks and lines, and a cut diff says so. *)

open! Core
open Ches_vcs
module Git = Ches_vcs_git

(** [View_id.of_string "vcs"]. *)
val id : Ches_tile.View_id.t

(** Read-only text, role [Major], [accepts_tab], title ["VCS"]. *)
val spec : Ches_tile.Spec.t

(** What has focus inside the view. *)
module Focus : sig
  type t =
    | Files
    | Branches
    | Commits
    | Diff
  [@@deriving sexp_of, equal, enumerate]

  (** The git panel a list focus shows ([None] for [Diff]). *)
  val panel : t -> Panel.Id.t option
end

module Repository_state : sig
  type t =
    | Unknown (** Never shown: nothing has run. *)
    | Detecting (** A detection of the current generation is in flight. *)
    | Found of Git.Repository.t
    | Not_a_repository of { cwd : string }
    | No_work_tree of
        { cwd : string
        ; message : string
        }
    | Failed of string (** Detection failed: one line, with the command. *)
  [@@deriving sexp_of]
end

(** The diff panel's content. *)
module Diff_state : sig
  type t =
    | Empty (** No repository or no selection yet. *)
    | No_diff (** The selected row has no diff target (a branch, an ignored file). *)
    | Loading of Git.Backend.diff_target (** The previous diff, if any, stays drawn. *)
    | Loaded of Git.Backend.diff_target * Diff.t
    | Failed of Git.Backend.diff_target * string
  [@@deriving sexp_of]
end

(** One command of the log: a [Run] step of one of the view's jobs. *)
module Log_entry : sig
  type t =
    { job : Job.Id.t
    ; command : string (** {!Exec.Spec.to_string_hum}, as started. *)
    ; status : string option
    (** {!Exec.Result.status_hum} once finished; [None] while running. *)
    ; output : string list
    (** A failed command's stderr tail (else empty), at most 5 lines, raw. *)
    ; stale : bool (** Its result was not used (superseded or a new generation). *)
    }
  [@@deriving sexp_of]
end

module Layout : sig
  module Mode : sig
    type t =
      | Side_by_side (** Lists column left, diff right. *)
      | Stacked (** Lists above, diff below. *)
      | Single (** Only the focused part. *)
    [@@deriving sexp_of, equal]
  end

  (** Rectangles relative to the content viewport's top-left corner. A part not
      drawn is [None]. *)
  type t =
    { mode : Mode.t
    ; lists : Geometry.Rect.t option
    (** The head summary rows, then the list panels, each a title row and its
        rows, with blank rows between them when there is room (see {!render}). *)
    ; diff : Geometry.Rect.t option
    (** A title row (the target), then the text, inset by a blank column on each
        side when there is room (see {!render}). *)
    ; log : Geometry.Rect.t option
    }
  [@@deriving sexp_of, equal]

  (** Content width from which the lists and the diff sit side by side: 80. *)
  val side_by_side_width : int

  (** Rows (after the log) from which a narrower viewport stacks them: 16. *)
  val stacked_rows : int

  (** Rows from which a visible log is drawn: 12. *)
  val log_rows : int

  (** The view's parts in a [width] by [rows] content viewport:
      - The log, when [log] and [rows >= log_rows]: the bottom [max 4 (rows / 3)]
        rows, full width. The rest is the main area.
      - Side by side when [width >= side_by_side_width]: the lists column is
        [Int.clamp_exn (width * 2 / 5) ~min:30 ~max:60] wide, then one separator
        column, then the diff.
      - Else stacked when the main area has at least [stacked_rows] rows: the lists
        take the top half (rounded down), then one separator row, then the diff.
      - Else single: the lists, or the diff when [focus] is [Diff], fill the main
        area.
      Rows and widths are never negative; a viewport of one row still gets a part. *)
  val compute : width:int -> rows:int -> focus:Focus.t -> log:bool -> t
end

type t [@@deriving sexp_of]

(** The backend's planner: [Git.Backend.plan] by default. Tests may give another
    (canned decisions over real fixture commands), so the view's action flow is
    testable apart from the git backend's plans. *)
type planner =
  Git.Repository.t
  -> Git.Backend.snapshot
  -> Git.Backend.action
  -> Backend.Plan.Decision.t

(** Nothing run, [Unknown], focus on Files, empty cursors, log hidden. [cwd] is
    absolute. *)
val create : ?plan:planner -> cwd:string -> unit -> t

(** [View_registry.Entry.install ~placement ~opens_in:Tab adapter (create ?plan ~cwd
    ())]; [placement] defaults to [Hidden]. *)
val entry
  :  ?placement:View_registry.Placement.t
  -> ?plan:planner
  -> cwd:string
  -> unit
  -> View_registry.Entry.t

(** {2 State queries, for rendering and tests} *)

val cwd : t -> string
val repository : t -> Repository_state.t

(** The last successful snapshot, kept while a refresh runs and after one fails. *)
val snapshot : t -> Git.Backend.snapshot option

(** The panels built from {!snapshot}, in order (Files, Branches, Commits). *)
val panels : t -> Git.Backend.item Panel.t list

(** A detection or refresh of the current generation is in flight. *)
val loading : t -> bool

(** The last refresh's failure (one line), until a refresh succeeds. *)
val refresh_error : t -> string option

val focus : t -> Focus.t

(** The list panel the diff follows (and [Tab] returns to): never [Diff]. *)
val list_focus : t -> Focus.t

(** A list panel's cursor ({!Panel.Cursor.empty} before any snapshot); [Diff] has
    none. *)
val cursor : t -> Focus.t -> Panel.Cursor.t

val diff : t -> Diff_state.t

(** The diff panel's text while it is focused (also {!Adapter.t.text_view}). *)
val text_view : t -> Ches_tile.Text_view.t option

val log_visible : t -> bool

(** Oldest first, at most 200 entries. *)
val log : t -> Log_entry.t list

(** The current generation's stamps (ids and lanes the view issued). *)
val stamps : t -> Stamps.t

(** The title of this view's mutation ({!Backend.Plan.t.title}) from its submission
    until the refresh after its [Finished] report is applied: actions are refused as
    busy meanwhile. *)
val mutation : t -> string option

(** {2 The adapter} *)

type action [@@deriving sexp_of]

(** Keys typed into the focused view, per the table above. *)
val interpret : t -> Ches_input.Key.t list -> action Ches_tile.Content_key.t

(** In the diff: end Visual, else back to the list panel. In a list: [None]. *)
val escape : t -> action option

(** [Shown] -> detect; [Saved] paths under the repository -> refresh, others
    ignored; [Job] events -> logged, and applied when current. *)
val signal : t -> View_registry.Signal.t -> action option

(** [rows] and [width] are the content viewport. *)
val perform
  :  t
  -> Ches_app.Controller.t
  -> context:View_registry.Context.t
  -> rows:int
  -> width:int
  -> action
  -> t * action View_registry.Ask.t View_registry.Outcome.t

(** The local commands of the current state (focus, repository state). *)
val commands : t -> Ches_tile.Local_command.t list

(** Keep cursors' scroll offsets and the diff's text cursor within the viewport's
    parts. Never changes the diff's text (that would post "Details updated"). *)
val fit : t -> rows:int -> width:int -> t

(** End Visual in the diff; focus and everything else are kept. *)
val leave : t -> t

(** Frame title: ["VCS"] before a repository is known; ["VCS: <root basename>
    (<branch>)"], or ["(detached at <revision>)"]; ["VCS: not a repository"];
    ["VCS: no work tree"] inside a bare repository or [.git]; ["VCS: error"] when
    detection failed. Body per {!Layout.compute}: the head
    summary (branch, upstream with ahead/behind or gone, operations in progress, a
    loading mark, the refresh error), the panels with section headers (fold marks,
    item counts) and their items, the diff panel's title (what it shows) and text,
    and the log. The not-a-repository and failed states say so plainly, with [g r]
    to retry.

    Padding: the diff's title and text are inset by one blank column on each side
    (the text wraps at the narrower width) when the diff part is at least 10
    columns wide, in every layout. The lists column puts one blank row after the
    summary, between the panels, and at its bottom. All three panels show from 9
    rows below the summary (3 titles, 6 body rows), with gaps only from 9 plus the
    gaps' rows, so no panel loses a row it had without them; a lone followed panel
    keeps its gaps while it has at least 3 body rows. *)
val render
  :  t
  -> hotkey_hints:bool
  -> focused:bool
  -> notice:string option
  -> pending:string option
  -> width:int
  -> rows:int
  -> Tile_shell.Content.t

(** Typed access in a {!View_registry}. *)
val key : t Type_equal.Id.t

(** All of the above as the registry's adapter; [text_area] is the diff rectangle
    below its title row and inside its padding while the diff is focused, else
    [None]. *)
val adapter : (t, action) View_registry.Adapter.t
