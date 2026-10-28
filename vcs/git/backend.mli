(** The git backend: {!Ches_vcs.Backend.S} over the parsers of this library.

    Panels, in order:
    - Files (["files"]): sections Conflicted, Untracked, Unstaged, Staged (and Ignored
      when {!Ches_vcs.Backend.Refresh.t} asks for it), empty sections omitted. Item
      keys are paths (a rename's new path). A [Changed] or [Renamed_or_copied] entry
      appears in Staged when its index side changed and in Unstaged when its work-tree
      side changed (both for a partially staged file); [Unmerged] in Conflicted;
      [Untracked] and [Ignored] in theirs. Entries keep git's order.
    - Branches (["branches"]): one section ["local"], keyed by branch name.
    - Commits (["commits"]): one section ["recent"], keyed by full hash.

    Actions arrive with the phases that need them: stage/unstage/discard in 3
    ({!action}), line staging in 4 ({!Target.t.Lines}), commit in 5 ({!Commit}),
    push/pull/fetch, branches and abort in 6 ({!Remote}, {!Branch_name}), merges,
    continue/skip and whole-file resolution in 7 ({!Operation}, {!Resolution}). *)

open! Core
open Ches_vcs

module Section : sig
  type t =
    | Conflicted
    | Untracked
    | Unstaged
    | Staged
    | Ignored
  [@@deriving sexp, equal, compare, enumerate]

  (** ["conflicted"], ["untracked"], ["unstaged"], ["staged"], ["ignored"]. *)
  val id : t -> Panel.Section_id.t

  val of_id : Panel.Section_id.t -> t option

  (** ["Conflicted"], ["Untracked files"], ["Unstaged changes"], ["Staged changes"],
      ["Ignored files"]. *)
  val title : t -> string
end

(** ["files"], ["branches"], ["commits"]. *)
val files_panel : Panel.Id.t

val branches_panel : Panel.Id.t
val commits_panel : Panel.Id.t

type snapshot =
  { repository : Repository.t
  ; refresh : Ches_vcs.Backend.Refresh.t
  ; status : Status.t
  ; branches : Branch_list.Branch.t list
  ; commits : Log.Commit.t list
  ; operations : In_progress.t list
  ; problems : string list
  (** Lesser failures the view should show (a failed branch list or log, a failed
      state-file read), each with the command line and stderr. *)
  }
[@@deriving sexp_of]

type item =
  | File of
      { section : Section.t
      ; entry : Status.Entry.t
      }
  | Branch of Branch_list.Branch.t
  | Commit of Log.Commit.t
[@@deriving sexp_of]

type diff_target =
  | Unstaged of string list (** Paths; [] = all unstaged changes. *)
  | Staged of string list
  (** Paths; [] = all staged changes. A staged rename gives [[original; path]]. *)
  | Untracked of string
  | Conflicted of string list (** Paths; combined diffs. *)
  | Commit of string (** Full hash. *)
[@@deriving sexp, equal]

(** The Files section whose changes a diff target shows, for hunk actions:
    [Unstaged _] -> [Unstaged], [Staged _] -> [Staged], [Untracked _] -> [Untracked],
    [Conflicted _] -> [Conflicted], [Commit _] -> [None] (a commit's diff has no
    actions). *)
val diff_section : diff_target -> Section.t option

(** What a Files action acts on. *)
module Target : sig
  type t =
    | File of
        { section : Section.t
        ; path : string
        (** The item's key in that section: a rename's new path; a key ending in
            ["/"] is an untracked nested repository. *)
        } (** One Files item (the selected row, or the file at the diff's cursor). *)
    | Section of Section.t (** A section header: every item of the section. *)
    | Hunk of
        { section : Section.t (** {!diff_section} of the diff it was chosen in. *)
        ; file : Diff.File.t (** As parsed from that diff. *)
        ; hunk : int (** 0-based, into [file.hunks]. *)
        ; selection : Patch.Selection.t
        (** [Whole] from the view. A [Lines] selection is planned exactly as
            [Lines { section; file; hunks = [ hunk, selection ] }]. *)
        } (** The hunk at the diff's cursor. *)
    | Lines of
        { section : Section.t (** {!diff_section} of the diff it was chosen in. *)
        ; file : Diff.File.t (** As parsed from that diff. *)
        ; hunks : (int * Patch.Selection.t) list
        (** 0-based indices into [file.hunks], strictly ascending, each with the
            lines chosen in it ([Whole] for a hunk the selection covers, which is
            equivalent to listing its lines). May be empty (nothing but header
            lines selected): refused as no change. *)
        }
    (** The lines of one file a Visual selection in the diff touches (phase 4),
        acted on by one patch ({!Patch.hunks}) and so atomically. *)
  [@@deriving sexp_of]
end

(** The phase 3 to 6 actions. Line staging (phase 4) is a {!Target.t.Lines}
    target, not a new action. *)
type action =
  | Stage of Target.t (** [s] *)
  | Unstage of Target.t (** [u] *)
  | Discard of Target.t (** [x] *)
  | Stage_all (** [S]: every Unstaged and Untracked item (not Conflicted). *)
  | Unstage_all (** [U]: every Staged item. *)
  | Finish_commit of
      { kind : Commit.Kind.t
      ; flags : string list (** The popup's enabled switches ({!Commit.flags}). *)
      ; message_file : string (** Absolute: {!Commit.Prepared.t.message_file}. *)
      } (** [Space g c] in the message buffer (phase 5). *)
  | Extend of { flags : string list } (** [e] in the commit popup (phase 5). *)
  | Fetch (** [f] (phase 6). *)
  | Pull of { flags : string list } (** The pull popup's [p] ({!Remote.Pull}). *)
  | Push of
      { target : Remote.Push.Target.t
      ; flags : string list (** {!Remote.Push.flags}. *)
      } (** The push popup's [p] and [u]. *)
  | Checkout of string (** Enter on a Branches item: the branch's name. *)
  | Checkout_previous (** [-] in Branches: [git switch -]. *)
  | Create_branch of string (** [n] in Branches: the prompt's name. *)
  | Abort of Operation.Kind.t (** [r a], [m a]. *)
  | Continue of Operation.Kind.t (** [r r], [m m] (phase 7). *)
  | Skip_rebase_commit (** [r s]. *)
  | Merge of
      { branch : string
      ; flags : string list (** {!Operation.merge_flags}. *)
      } (** The merge popup's [m]. *)
  | Resolve of
      { path : string (** A Conflicted item's key. *)
      ; side : Resolution.Side.t
      } (** The resolve popup ([x] on a Conflicted item). *)
[@@deriving sexp_of]

(** Contract details beyond {!Ches_vcs.Backend.S}:

    - [name] is ["git"]; [Repository] is {!Ches_vcs_git.Repository}.
    - [detect]/[detected]: {!Repository.detect}/{!Repository.detected}.
    - [refresh repo r]: [Run (Status.command ~ignored:r.ignored)],
      [Run Branch_list.command], [Run (Log.command ~limit:r.log_limit)], then
      [Read_file] of every {!In_progress.reads} of [repo.git_dir]; all in
      [repo.root].
    - [snapshot]: Error if the status step did not succeed (or its output does not
      parse), with the command line, status and stderr. A failed branch list or
      in-progress read adds a [problems] entry and gives [[]]. A failed log gives
      [[]], with a [problems] entry unless the status says there is no commit yet
      ([branch.oid (initial)]). Output cut at its limit ({!Exec.Result.cut_at_limit})
      parses with [~cut:true].
    - [summary]: branch and revision (7 characters) from the status headers; upstream
      from [branch.upstream] and [branch.ab], [gone] when the current branch's
      {!Branch_list.Tracking.t} is [Gone] (then ahead and behind are 0);
      [operations] by {!In_progress.describe}.
    - [diff_target]: Files headers: Unstaged -> [Unstaged []], Staged -> [Staged []],
      Conflicted -> [Conflicted] of all its paths, Untracked and Ignored -> [None].
      Files items: Unstaged -> [Unstaged [path]], Staged -> [Staged [path]] (or
      [[original; path]] for a rename or copy), Untracked -> [Untracked path], except
      [None] for a key ending in ["/"] (a nested repository or an untracked
      directory, which [diff --no-index] cannot show), Conflicted -> [Conflicted
      [path]], Ignored -> [None]. Commits items -> [Commit
      hash]; Branches rows and the Commits header -> [None]. Unknown panels or rows ->
      [None].
    - [diff]: one [Run] of {!Diff_output.command}: [Unstaged]/[Conflicted] ->
      [Worktree], [Staged] -> [Index], [Untracked] -> [Untracked], [Commit] ->
      [Commit].
    - [parse_diff]: Error unless the step exited with one of
      {!Diff_output.ok_exits} or was cut at its limit; then {!Diff_output.parse}.
    - [plan]: below.

    {2 [plan]: the phase 3 and 4 command plans}

    [plan repo snapshot action] decides against [snapshot] (the one the action was
    chosen in) and never reads anything. Entries are looked up in
    [snapshot.status.entries] by section ({!Section}, as the Files panel places them)
    and key.

    {3 Commands}

    Every step is [Run (Cli.mutate ~cwd:repo.root args)] whose [args] start with
    ["--literal-pathspecs"] (git's global option, so a path such as [a*.txt] is never
    a glob), then the subcommand; paths follow ["--"], in [status] order. So a log
    line reads [git --no-pager -c color.ui=false -c core.quotepath=false
    --literal-pathspecs add --all -- a.txt]. The commands:
    - add: [add --all -- P...] ([--all] also stages a deletion, and a both-deleted
      conflict's resolution).
    - restore-staged: [restore --staged -- P...]; on an unborn branch (no HEAD:
      [status.branch.oid = None]), [reset --quiet -- P...] instead (restore needs HEAD;
      [rm --cached] refuses a partially staged file).
    - restore-worktree: [restore --worktree -- P...] (the work tree from the index).
    - restore-head: [restore --source=HEAD --staged --worktree -- P...] (a file not
      in HEAD is removed from both); on an unborn branch [rm --force --quiet -- P...].
    - clean: [clean --force --quiet -- P...] (untracked files only).
    - apply: two steps, [apply <flags> --whitespace=nowarn --check] then [apply
      <flags> --whitespace=nowarn], both with [~stdin:(Data patch)] where [patch] is
      {!Patch.hunk} [file ~hunk selection ~reverse:(flags has --reverse)] (for
      [Lines], {!Patch.hunks} [file hunks ~reverse]); flags are
      [--cached] (stage), [--cached --reverse] (unstage), [--reverse] (discard
      unstaged), [--index --reverse] (discard staged). A failed check skips the apply.
    For a [Renamed_or_copied] entry, the commands that touch the index side name both
    paths, [original] then [path] (restore-staged, restore-head); everything else
    names an entry by its key.

    {3 Decisions}

    [rewrites_worktree] is true exactly for [Discard] plans. Every [Discard] that is
    not refused is a [Confirm]; [Stage], [Unstage], [Stage_all] and [Unstage_all] that
    are not refused are [Run]. In the texts below, [<path>] is the key (a rename's new
    path), [<i>/<n>] is the hunk's 1-based index and the file's number of kept hunks,
    and [<N> files] is a count ("1 file", "2 files"). Paths are raw bytes: the view
    escapes them for display.

    Stage:
    - [File Unstaged]: add. Title ["Stage <path>"].
    - [File Untracked]: add; a key ending in ["/"] is refused: ["<path> is a nested
      repository: Ches does not stage it; nothing ran"] (git would add a bare gitlink
      without [.gitmodules]). Title ["Stage <path>"].
    - [File Conflicted] (owner decision, Magit's way): add, which marks it resolved;
      no confirmation, no check for leftover conflict markers. Title ["Mark <path>
      resolved"].
    - [Section Unstaged]: add of every Unstaged key. ["Stage unstaged changes (<N>
      files)"]. [Section Untracked]: add of every Untracked key except nested
      repositories (left out, see below). ["Stage untracked files (<N> files)"].
      [Section Conflicted]: add of every Conflicted key. ["Mark <N> files
      resolved"].
    - [Hunk Unstaged]: apply [--cached]. ["Stage hunk <i>/<n> of <path>"]. (An
      intent-to-add file's hunk stages its content; verified.)
    - [Hunk Untracked]: as [File Untracked] of the file's path (an untracked file's
      diff is one hunk: the whole file).
    - [Stage_all]: add of every Unstaged key and every Untracked key except nested
      repositories (left out); Conflicted items are not included (each is marked
      resolved deliberately, with [s]). ["Stage all changes (<N> files)"].
    - Refused: [File]/[Section]/[Hunk] in Staged: ["<path> is already staged; nothing
      ran"] (a section: ["Already staged; nothing ran"]); Ignored: ["<path> is
      ignored; nothing ran"] (["Ignored files are not staged; nothing ran"]); a
      [Hunk] in Conflicted: the conflict refusal below; [Stage_all] with nothing to
      include: ["Nothing to stage; nothing ran"].

    Unstage:
    - [File Staged]: restore-staged (both paths of a rename or copy, so the original
      returns to the index and the new path becomes untracked). ["Unstage <path>"].
    - [Section Staged] and [Unstage_all]: restore-staged of every Staged entry (both
      paths of renames and copies). ["Unstage staged changes (<N> files)"] /
      ["Unstage all changes (<N> files)"].
    - [Hunk Staged]: apply [--cached --reverse]. A renamed file's hunk is a change of
      the new path ({!Patch.hunk}), so the rename stays staged; a new file's only
      hunk unstages the file (it becomes untracked). ["Unstage hunk <i>/<n> of
      <path>"].
    - Refused: Unstaged, Untracked or Ignored targets: ["<path> is not staged; nothing
      ran"] (a section: ["Nothing staged here; nothing ran"]); [Unstage_all] with no
      Staged entry: ["Nothing staged; nothing ran"].

    Discard (every one confirmed, default No; the [Confirm.message] says what is lost):
    - [File Unstaged]: restore-worktree. Confirm title ["Discard changes"], message
      ["Discard the unstaged changes to <path>? They are lost; staged changes are
      kept."]. Plan title ["Discard unstaged changes to <path>"].
    - [File Untracked]: clean. Title ["Delete untracked file"], message ["Delete
      <path>? It is not in git and cannot be recovered."]. Plan ["Delete <path>"].
    - [File Staged] (decision: the staged change is thrown away in the index and the
      work tree, i.e. the file returns to HEAD; refused when the file also has
      unstaged changes, so nothing unshown is lost): restore-head (both paths of a
      rename or copy). Title ["Discard changes"]; message by the entry's index
      change: [Added] or [Copied], or any entry on an unborn branch: ["Delete <path>?
      It is new and only staged: its content is lost."]; [Renamed]: ["Undo the rename
      of <original> to <path>? <path> is deleted with its staged changes and
      <original> is restored from HEAD."]; [Deleted]: ["Restore <path> from HEAD? Its
      staged deletion is undone."]; otherwise ["Discard the staged changes to <path>?
      They are lost: it returns to HEAD in the index and the work tree."]. Plan
      ["Discard staged changes to <path>"].
    - [Section Unstaged]: restore-worktree of every applicable Unstaged key. Title
      ["Discard changes"], message ["Discard the unstaged changes to <N> files? They
      are lost; staged changes are kept."]. Plan ["Discard unstaged changes (<N>
      files)"].
    - [Section Untracked]: clean of every untracked file (nested repositories left
      out). ["Delete untracked files"], ["Delete <N> untracked files? They are not in
      git and cannot be recovered."]. Plan ["Delete untracked files (<N> files)"].
    - [Section Staged]: restore-head of every applicable Staged entry. ["Discard
      changes"], ["Discard the staged changes to <N> files? They are lost: the files
      return to HEAD in the index and the work tree (new files are deleted)."]. Plan
      ["Discard staged changes (<N> files)"].
    - [Hunk Unstaged]: apply [--reverse]. ["Discard hunk"], ["Discard hunk <i>/<n> of
      <path>? Its unstaged lines are lost."]. Plan ["Discard hunk <i>/<n> of
      <path>"].
    - [Hunk Staged]: apply [--index --reverse]; refused when the file also has
      unstaged changes (as [File Staged]). ["Discard hunk"], ["Discard staged hunk
      <i>/<n> of <path>? It is removed from the index and the work tree and lost."].
      Plan ["Discard staged hunk <i>/<n> of <path>"].
    - [Hunk Untracked]: as [File Untracked] of the file's path.
    - Refused: an Unstaged intent-to-add entry (worktree side [Added]): ["<path> is
      intent-to-add (git add -N): discarding would empty it; nothing ran"] (git
      restore truncates such a file: verified); any entry with a submodule:
      ["<path> is a submodule: discard is not supported; nothing ran"]; a nested
      repository: ["<path> is a nested repository: delete it outside Ches; nothing
      ran"] (git clean silently keeps it); a Staged entry that also has unstaged
      changes: ["<path> also has unstaged changes: discard or stage them first;
      nothing ran"]; Ignored: ["<path> is ignored; nothing ran"] (the section:
      ["Ignored files are not discarded; nothing ran"]).

    Conflicted (owner decision): [Unstage], [Discard] and every [Hunk] action on a
    Conflicted file or section are refused (phase 7 texts): a file: ["<path> is
    conflicted: take a side with x, or resolve it in the editor (Space x), then
    stage it (s) to mark it resolved; nothing ran"]; a section: ["Resolve conflicted
    files one at a time (x on a file); nothing ran"]; a hunk or lines: ["Resolve
    conflicts in the editor: Enter opens the file at the conflict, Space x u, l, a
    or b keeps a side; nothing ran"]. Only [Stage] (add) applies, and [Resolve]
    (phase 7) takes a whole side. The view opens {!Resolution.popup} for [x] on a
    Conflicted item instead of planning [Discard].

    Hunk targets, before the rules above: a file without line actions
    ({!Diff.File.line_actions}), an out-of-range index, or any other {!Patch.hunk}
    error is refused with that error's message; [Hunk] in Untracked never builds a
    patch.

    Sections and [S]/[U]: entries an action does not apply to (the refusals above:
    nested repositories, intent-to-add entries for discard, submodules for discard,
    partially staged entries for discarding staged changes) are left out, and every
    text names them once, appended: plan title [" (left out: <path>, <path>)"], and
    the confirmation message [" Left out: <path> (nested repository), <path>
    (submodule)."], with the labels [nested repository], [submodule],
    [intent-to-add] and [also has unstaged changes]. Counts in texts are singular
    for one ("1 file"). When nothing remains, the action is refused with the first
    left-out entry's refusal (so [S] with only nested repositories gives the nested
    repository's refusal, not "Nothing to stage"). A section absent from the
    snapshot is refused: ["Nothing here; nothing ran"].

    A [File] or [Hunk] target whose path is not in that section of the snapshot is
    refused: ["<path> is no longer listed; refresh (g r); nothing ran"]. The
    intent-to-add discard refusal covers an Unstaged hunk too: reverse-applying its
    "new file" patch would delete the file.

    {3 Lines (phase 4)}

    A [Lines { section; file; hunks }] target is planned like a [Hunk] of the same
    section, with one patch for all its hunks ({!Patch.hunks}, so a selection across
    hunks applies atomically: one [--check], one apply) and these texts, where [<N
    lines>] is the number of selected changes ({!Patch.changes}: [Added] and
    [Removed] lines; ["1 line"], ["3 lines"]) and [<path>] the file's
    {!Diff.File.path}. In order, the first that applies:
    - Conflicted: the conflict refusal (as [Hunk]).
    - Untracked: [Stage] and [Discard] are refused with ["Stage the whole untracked
      file first (s on its row); nothing ran"] (no [git add -N] here: line actions
      need the file in the index); [Unstage]: ["<path> is not staged; nothing ran"].
      Ignored: as [File Ignored].
    - A {!Patch.changes} error (a file without line actions, [Type_changed], an
      index out of range, hunks out of order): refused with its message (["Line
      actions do not apply to <path>: it is binary"]).
    - No selected change ({!Patch.changes} is 0: only context, [@@], header or
      marker lines, or an empty [hunks]): ["No changes selected; nothing ran"].
    - Not in that section of the snapshot: the "no longer listed" refusal.
    - Then by verb and section, the apply flags as for [Hunk]:
      - [Stage], Unstaged: apply [--cached]. Run, ["Stage <N lines> of <path>"].
        Some lines of an intent-to-add file stage as its creation holding only
        them; unstaging some lines of a staged new file keeps it, with the
        unselected lines (both verified).
      - [Unstage], Staged: apply [--cached --reverse]. Run, ["Unstage <N lines> of
        <path>"].
      - [Discard], Unstaged: refused as [Hunk Unstaged] (intent-to-add, submodule);
        else apply [--reverse], confirmed: title ["Discard lines"], message
        ["Discard <N lines> of <path>? Their unstaged changes are lost."] (one:
        ["Discard 1 line of <path>? Its unstaged change is lost."]), plan
        ["Discard <N lines> of <path>"].
      - [Discard], Staged: refused as [Hunk Staged] (also has unstaged changes,
        submodule); else apply [--index --reverse], confirmed: title ["Discard
        lines"], message ["Discard <N staged lines> of <path>? Their changes are
        removed from the index and the work tree and lost."] (one: ["Discard 1
        staged line of <path>? Its change is removed from the index and the work
        tree and lost."]), plan ["Discard <N staged lines> of <path>"].
      - [Stage] in Staged: ["<path> is already staged; nothing ran"]; [Unstage] in
        Unstaged: ["<path> is not staged; nothing ran"].
    A selection that no longer matches the index or work tree (the diff is stale)
    fails at the [--check] step and changes nothing.

    {3 Commits (phase 5)}

    [Finish_commit { kind; flags; message_file }] and [Extend { flags }] are refused
    with {!Commit.refusal} of [snapshot.status] and [Choice.Message { kind; flags }]
    / [Choice.Extend { flags }] (an unknown flag, conflicted files, amending an
    unborn branch, nothing staged without [--allow-empty]). Otherwise [Run], one step
    [Run (Cli.mutate ~cwd:repo.root args)], [rewrites_worktree = false] (the view
    still reconciles open buffers afterwards: hooks may rewrite files), no
    [--literal-pathspecs] (no paths):
    - [Commit]: [-c core.commentChar=# commit --cleanup=strip <flags> -F
      <message_file>]. Title ["Commit"].
    - [Amend]: [-c core.commentChar=# commit --cleanup=strip --amend <flags> -F
      <message_file>]. Title ["Amend HEAD"].
    - [Extend]: [commit --amend --no-edit <flags>]. Title ["Extend HEAD"].
    [<flags>] in {!Commit.flags} order. [-c core.commentChar=#] makes
    [--cleanup=strip] remove the template's comments whatever the user's
    [core.commentChar]; [-F] and [--no-edit] never start an editor. An empty message
    after stripping, or a rejecting hook, fails the step (git's stderr says why).

    {3 Remotes and branches (phase 6)}

    Network steps are [Run (Cli.network ~cwd:repo.root args)] (kind [Network],
    streamed; the runner adds the authentication environment) and each passes
    [--progress] (git prints progress only to a terminal otherwise). The others are
    [Run (Cli.mutate ~cwd:repo.root args)]. One step per plan; no
    [--literal-pathspecs] (no paths). Refusal texts used below:
    - detached ([status.branch.head = None]): ["HEAD is detached: check out a branch
      first; nothing ran"];
    - unborn ([status.branch.oid = None]): ["There is no commit yet; nothing ran"];
    - in progress: the first of [snapshot.operations] other than [Bisect]:
      ["<In_progress.describe> in progress: finish or abort it first; nothing ran"];
    - conflicted (any [Unmerged] entry): ["Resolve the conflicted files first (s
      marks one resolved); nothing ran"];
    - an unknown flag: ["Unknown push switch <flag>; nothing ran"] (["pull"]).
    The current branch is [status.branch.head]; its upstream's name is
    [status.branch.upstream]; its [Branch_list.Upstream.t] (remote, merge, tracking)
    is that of the [snapshot.branches] entry with [current].

    - [Fetch]: never refused. [fetch --progress --prune]. Run, title ["Fetch"],
      [rewrites_worktree = false].
    - [Pull { flags }]: refused, the first that applies: unknown flag; in progress
      (before detached: a stopped rebase detaches HEAD); detached; no upstream:
      ["<branch> has no upstream: push it with P u first; nothing ran"]; a [Gone]
      upstream: ["The upstream <upstream> is gone; nothing ran"]; conflicted. Else Run, [rewrites_worktree = true]: without
      [--rebase], [pull --progress --ff-only --no-rebase] (fast-forward only,
      whatever [pull.rebase] says), title ["Pull from <upstream>"]; with it, [pull
      --progress --rebase], title ["Pull from <upstream> (rebase)"]. A diverged
      fast-forward-only pull fails and changes nothing ({!Remote.hint} explains).
    - [Push { target; flags }]: refused, the first that applies: unknown flag; in
      progress (as for pull); detached; unborn; [Upstream] with no upstream: ["<branch> has no upstream: P u
      pushes it to origin/<branch> and sets it; nothing ran"]; [Upstream] whose
      current branch has no [Branch_list] upstream (the branch list failed): ["The
      branch list could not be read; refresh (g r); nothing ran"]. Else, with
      [<flags>] in {!Remote.Push.flags} order:
      - [Upstream]: [push --progress <flags> --end-of-options <remote>
        refs/heads/<branch>:<merge>] (explicit, so [push.default] does not matter);
        [<dest>] is [<upstream>].
      - [Set_upstream]: [push --progress --set-upstream <flags> --end-of-options
        origin refs/heads/<branch>:refs/heads/<branch>]; [<dest>] is
        [origin/<branch>].
      Plan title ["Push <branch> to <dest>"], [rewrites_worktree = false]. Without
      [--force-with-lease], Run. With it, the title is ["Force-push <branch> to
      <dest>"] and the decision a [Confirm]: title ["Force push"], message
      ["Force-push <branch> to <dest>? Commits on <dest> that <branch> does not
      contain are lost. git refuses if <dest> moved since the last fetch."].
    - [Checkout name]: refused, the first that applies: [name] not among
      [snapshot.branches]: ["<name> is no longer listed; refresh (g r); nothing
      ran"]; it is the current branch: ["Already on <name>; nothing ran"]; in
      progress; conflicted. Else Run [switch --end-of-options <name>], title ["Check
      out <name>"], [rewrites_worktree = true]. Uncommitted changes git would
      overwrite fail the step (git refuses; nothing changes).
    - [Checkout_previous]: refused: in progress; conflicted. Else Run [switch -],
      title ["Check out the previous branch"], [rewrites_worktree = true]. Without a
      previous branch, git fails the step.
    - [Create_branch name]: refused, the first that applies: unborn: ["There is no
      commit yet: commit before branching; nothing ran"]; in progress (git refuses
      to switch mid-merge); {!Branch_name.refusal}
      [~existing] (the names of [snapshot.branches]) with ["; nothing ran"]
      appended. Else Run [switch --create <name>] (the new branch at HEAD, checked
      out, uncommitted changes kept), title ["Create branch <name>"],
      [rewrites_worktree = false].
    - [Abort operation]: refused unless {!Operation.in_progress}: ["No rebase in
      progress; nothing ran"] (["No merge in progress; nothing ran"]). Else a
      [Confirm], [rewrites_worktree = true]:
      - [Rebase]: title ["Abort rebase"], message ["Abort the rebase? The branch
        returns to where it was before the rebase; commits and conflict resolutions
        made during it are lost."], plan [rebase --abort], title ["Abort rebase"].
      - [Merge]: title ["Abort merge"], message ["Abort the merge? Its changes and
        your conflict resolutions are lost; HEAD stays where it is."], plan [merge
        --abort], title ["Abort merge"].

    {3 Merges, rebases and conflicts (phase 7)}

    One or two [Run (Cli.mutate ~cwd:repo.root args)] steps, refusal texts as in
    phase 6 (in progress, conflicted, unborn), plus not-in-progress: ["No rebase in
    progress; nothing ran"] / ["No merge in progress; nothing ran"]. Steps that git
    may answer by starting an editor ([rebase --continue] and [--skip], [commit
    --no-edit --cleanup=strip]) also set [GIT_EDITOR=true] in the spec's [env] (the runner forces it
    for every child as well, {!Ches_vcs_host.Auth}), so the prepared message is kept
    as it is. Every plan below has [rewrites_worktree = true]: it is refused while a
    buffer in the repository is dirty (save the resolutions first) and followed by
    reconciliation.
    - [Merge { branch; flags }]: refused, the first that applies: an unknown flag
      (["Unknown merge switch <flag>; nothing ran"]); unborn; in progress;
      conflicted; [branch] not among [snapshot.branches] (["<branch> is no longer
      listed; refresh (g r); nothing ran"]); [branch] is the current branch
      (["Cannot merge <branch> into itself; nothing ran"]). Else Run [merge --no-edit
      <flags> --end-of-options <branch>] ([<flags>] in {!Operation.merge_flags}
      order), title ["Merge <branch>"], with [" (no fast-forward)"] or [" (fast-forward
      only)"] appended for [--no-ff] / [--ff-only]. Conflicts stop it: the step fails
      and a merge is in progress ({!Operation.stopped_hint}).
    - [Continue Rebase]: refused: not in progress; conflicted. Else Run [rebase
      --continue], title ["Continue rebase"]. It may stop again on the next commit's
      conflicts.
    - [Continue Merge]: refused: not in progress; conflicted. Else Run [commit
      --no-edit --cleanup=strip] (git's prepared merge message, without its [#
      Conflicts:] comment lines, which [--no-edit] alone would keep), title
      ["Commit merge"].
    - [Skip_rebase_commit]: refused: not in progress. Else a [Confirm]: title ["Skip
      commit"], message ["Skip the commit being applied? Its changes are left out of
      the rebased branch."], plan [rebase --skip], title ["Skip commit"].
    - [Resolve { path; side }]: refused unless [path] is an [Unmerged] entry:
      ["<path> is not conflicted; nothing ran"]; [Markers] for a conflict other than
      [Both_modified] or [Both_added]: ["<path> has no conflict markers to restore
      (<Conflict.to_string_hum>); nothing ran"]. Else a [Confirm], the steps with
      [--literal-pathspecs] and [-- <path>] as the phase 3 commands are:
      - [Ours] or [Theirs] where {!Resolution.has_file}: [checkout --ours] (or
        [--theirs]) then [add], so the file is marked resolved. Confirm title
        ["Resolve <path>"], message ["Take <label> for <path>? The other side's
        changes and any edits to the file are lost; it is marked resolved."], plan
        ["Take ours for <path>"] / ["Take theirs for <path>"]. [<label>] is ["ours
        (<ours label>)"] or ["theirs (<theirs label>)"], {!Resolution.labels}.
      - [Ours] or [Theirs] without the file on that side: [rm --quiet] (the
        resolution is the deletion). Message ["Resolve <path> by deleting it, as
        <label> did? Any edits to the file are lost."], plan ["Delete <path>
        (resolved)"].
      - [Markers]: [checkout --merge] (the file is conflicted again, with markers;
        it stays unstaged). Message ["Restore the conflict markers in <path>? Edits
        to the file are lost."], plan ["Restore conflict markers in <path>"]. *)
include
  Ches_vcs.Backend.S
  with type Repository.t = Repository.t
   and type Snapshot.t = snapshot
   and type Item.t = item
   and type Diff_target.t = diff_target
   and type Action.t = action
