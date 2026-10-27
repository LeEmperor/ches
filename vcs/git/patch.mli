(** Patches for [git apply], built from a parsed diff ({!Ches_vcs.Diff}): the text that
    applies (or, with [git apply --reverse], removes) part of one file's changes. Pure.
    Phase 3 builds whole hunks; phase 4 adds selected lines (a new {!Selection.t}
    constructor), with the same entry point.

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
  (* Phase 4 adds [Lines of int list] (indices into [Diff.Hunk.t.lines]): unselected
     [Removed] lines become context and unselected [Added] lines are dropped when
     applying forward, the other way round when [reverse]; headers recomputed. *)
  [@@deriving sexp, equal]
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

(** A path with its [prefix] ([a/] or [b/]) as {!hunk} writes it: [a/x y] verbatim,
    or a name with a tab quoted whole, prefix included, with the tab as backslash-t. *)
val quote : prefix:string -> string -> string
