(** Patches for [git apply], built from a parsed diff ({!Ches_vcs.Diff}): the text that
    applies (or, with [git apply --reverse], removes) part of one file's changes. Pure.
    Phase 3 builds whole hunks ({!hunk}); phase 4 adds selected lines
    ({!Selection.t.Lines}) and patches of several hunks of one file ({!hunks}).

    How the backend applies a patch ({!Backend.plan}), always at the work-tree root,
    patch text on stdin ({!Ches_vcs.Exec.Stdin.Data}), each command first with
    [--check] (a mutation stops at its first failed step, so a failing check skips the
    apply):
    - stage a hunk of the unstaged diff: [git apply --cached] of the patch;
    - unstage a hunk of the staged diff: [git apply --cached --reverse];
    - discard a hunk of the unstaged diff: [git apply --reverse] (the work tree);
    - discard a hunk of the staged diff: [git apply --index --reverse] (the index and
      the work tree; git refuses when the file's work-tree text differs from the
      index, so the backend refuses first when the file has unstaged changes).
    Every apply passes [--whitespace=nowarn]: a user's [apply.whitespace=error] would
    otherwise refuse to stage a line with trailing whitespace exactly as shown.

    Verified against git 2.43 (fixture repositories): synthesized headers below with
    no [index] line, names with spaces without git's trailing tab, CRLF lines,
    ["\ No newline at end of file"], new and deleted files both ways, a staged rename's
    hunk unstaged as a modification of the new path (the rename stays staged), an
    intent-to-add file's hunk staged with [--cached]. *)

open! Core
open Ches_vcs

module Selection : sig
  (** Which lines of the hunk the patch carries. *)
  type t =
    | Whole (** Every line: the hunk exactly as the diff showed it. *)
    | Lines of int list
    (** The changes on these lines (0-based indices into [Diff.Hunk.t.lines], in any
        order, duplicates ignored; a hunk itself appears once in {!hunks}). Only [Added] and [Removed] lines are changes:
        a [Context] or [No_newline] index selects nothing. Applied forward, an
        unselected [Removed] line becomes context and an unselected [Added] line is
        dropped; with [reverse], an unselected [Added] line becomes context and an
        unselected [Removed] line is dropped. Every index selecting every change is
        equivalent to [Whole]. *)
  [@@deriving sexp, equal]

  (** The number of [Added] and [Removed] lines it selects in the hunk (every one
      for [Whole]); indices out of range count nothing. *)
  val changes : Diff.Hunk.t -> t -> int
end

(** The patch for hunk [hunk] (0-based, into [file.hunks]) of [file]. [reverse] says
    how it will be applied ([git apply --reverse]): a [Whole] hunk's text is the same
    either way (git reverses it); a line selection (phase 4) depends on it.

    Text, every line ending in ["\n"]:
    {v
    diff --git a/P b/P
    new file mode M            (Added only: M = new_mode)
    deleted file mode M        (Deleted only: M = old_mode)
    --- a/P                    (--- /dev/null for Added)
    +++ b/P                    (+++ /dev/null for Deleted)
    @@ -a,b +c,d @@ section    (the hunk's header, verbatim)
    <each line>
    v}
    That is [Whole]; a [Lines] selection is {!hunks} of the one hunk (its own [@@]
    line, its file header lines by its sides).
    [P] is the file's {!Diff.File.path} (the new path; the old path of a deleted
    file), for both sides: a renamed or copied file's hunk is a change of the new path
    alone, so applying or reversing it never adds or undoes the rename. Mode changes,
    similarity, rename/copy and [index] lines are left out (a hunk carries content
    only). A name is written as git writes it: in double quotes, C-style, when it
    contains a double quote, a backslash or a control byte (below 0x20, or 0x7f),
    with git's backslash escapes (a b t n v f r, the double quote, the backslash) and
    three-digit octal for other control bytes; otherwise verbatim, spaces and bytes
    above 0x7f included, with no trailing tab. Lines: a space, [+] or [-] by
    {!Diff.Line.Kind.t} (whatever the parsed prefix, so an empty context line gets
    its space), then the text, which keeps any carriage return; a [No_newline] line
    is its prefix and text as parsed (the backslash line git wrote).

    An error (the message is a notice: one line, naming the path) when the file has
    no line actions ({!Diff.File.line_actions}: binary, submodule, combined, unmerged,
    mode-only, rename-only), its change is [Type_changed], the index is out of range,
    an [Added] file has no [new_mode] or a [Deleted] one no [old_mode]. *)
val hunk
  :  Diff.File.t
  -> hunk:int
  -> Selection.t
  -> reverse:bool
  -> string Or_error.t

(** The patch for several hunks of [file] at once, each with its selection, applied
    atomically by one [git apply] (phase 4: a Visual selection across hunks). [hunks]
    lists 0-based indices into [file.hunks], strictly ascending (an error
    otherwise). [hunk file ~hunk:i Whole ~reverse] is [hunks file [ i, Whole ]
    ~reverse] except for the [@@] line, which {!hunk} keeps verbatim; [hunk] of a
    [Lines] selection is exactly [hunks] of that one hunk.

    The file header is {!hunk}'s, then each hunk with at least one selected change,
    in order (hunks whose selection carries no change are left out):
    - Lines. Forward ([reverse = false]): context lines, every [Removed] line (an
      unselected one as context) and the selected [Added] lines. With [reverse]:
      context lines, every [Added] line (an unselected one as context) and the
      selected [Removed] lines. So the side [git apply] matches against (the old side
      forward, the new side reversed) is exactly the diff's, and the other side holds
      only the selected changes.
    - ["\ No newline at end of file"]: each side keeps the newline state its lines
      had in the diff (a line kept as context keeps the side it came from: the old
      side's state forward, the new side's reversed), except that a line which is no
      longer the last line of its side gets a newline. A context line whose state
      differs between the sides is written as a [-] line and a [+] line, each
      followed by the marker where its side lacks the newline (e.g. forward, an
      unselected old last line without a newline followed by selected added lines
      becomes [-x], the marker, [+x], then the added lines). The marker is the
      first [No_newline] line's prefix and text as parsed.
    - [@@] lines: ["@@ -a,b +c,d @@"] then [" " ^ section] when the hunk has one,
      counts always written. The matched side's start is the diff's ([-a] forward,
      [+c] reversed); the other side's is shifted by the line-count difference of
      the earlier hunks of this patch (a start names the line before the hunk when
      its count is 0, as git does), so every hunk's header is consistent with the
      patch, whichever hunks it leaves out.
    - Added and deleted files: an [Added] file keeps ["new file mode"] and
      [--- /dev/null] only when the patch's old side is empty; otherwise (unstaging
      or discarding part of a staged or intent-to-add new file's lines) it is
      written as a modification of the path ([--- a/P], no mode line), so the file
      stays with the unselected lines. Likewise a [Deleted] file keeps ["deleted
      file mode"] and [+++ /dev/null] only when the patch's new side is empty
      (staging some of a deleted file's lines removes those lines from the index
      and keeps the file); reversed, a deleted file's selected lines are restored
      as a new file holding only them.

    Errors (one line, naming the path): {!hunk}'s, with ["Line actions"] for
    ["Hunk actions"] (["Line actions do not apply to <path>: it is binary"]; {!hunk}
    of a [Lines] selection says ["Line actions"] too), a hunk index out of range, a
    line index out of range (["Line <l> of hunk <i>/<n> of <path> does not exist (it
    has <k>)"], 1-based), indices not strictly ascending (["Hunks of <path> must be
    listed once each, in order"]), and no selected change at all (["No changes
    selected in <path>"], which {!Backend.plan} refuses earlier with its own text,
    see {!changes}). Checked in that order: line actions, hunk range, line range
    (a negative index is out of range), order, the [Added]/[Deleted] mode (reported
    even when the mode line would not be written), then no change. *)
val hunks
  :  Diff.File.t
  -> (int * Selection.t) list
  -> reverse:bool
  -> string Or_error.t

(** The number of [Added] and [Removed] lines [hunks] selects, after the checks
    {!hunks} makes on the file and the indices (the same errors, except that no
    selected change is [Ok 0] rather than an error; an empty list is [Ok 0]). *)
val changes : Diff.File.t -> (int * Selection.t) list -> int Or_error.t

(** A path with its [prefix] ([a/] or [b/]) as {!hunk} writes it: [a/x y] verbatim,
    or a name with a tab quoted whole, prefix included, with the tab as backslash-t. *)
val quote : prefix:string -> string -> string
