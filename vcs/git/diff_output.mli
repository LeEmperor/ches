(** The diff panel's git commands ([diff], [diff --cached], [diff --no-index],
    [show]) and the parser of their patch output into {!Ches_vcs.Diff.t}. *)

open! Core
open Ches_vcs

module Source : sig
  type t =
    | Worktree of { paths : string list }
    (** [git diff]: index to work tree, limited to [paths] ([] = all). An unmerged
        path gives a combined ([diff --cc]) diff. *)
    | Index of { paths : string list }
    (** [git diff --cached]: HEAD to index (to the empty tree before the first
        commit, which git handles itself). *)
    | Untracked of string
    (** [git diff --no-index -- /dev/null <path>]: the whole file as added. Git exits
        1 when they differ, which is the normal answer. *)
    | Commit of string (** [git show <hash>]: the commit's header and message, then
        its diff (combined for a merge). *)
  [@@deriving sexp, equal]
end

(** [Cli.read ~cwd] of the source's command with [--no-color --no-ext-diff
    --no-relative --src-prefix=a/ --dst-prefix=b/ --find-renames --submodule=short],
    paths after [--]. [Commit] adds [--no-show-signature --format=fuller
    --date=iso-strict] and passes the hash after [--end-of-options], then [--]. *)
val command : cwd:string -> Source.t -> Exec.Spec.t

(** Exit codes that mean success for the source: [[0; 1]] for [Untracked], [[0]]
    otherwise. *)
val ok_exits : Source.t -> int list

(** Parse patch output:
    - Lines before the first file header go to [preamble] (a [show]'s commit
      header).
    - A file starts at ["diff --git "], ["diff --cc "] or ["diff --combined "]. Its
      header lines up to the first hunk are kept verbatim in [header] and read for
      [old mode]/[new mode]/[new file mode]/[deleted file mode], [similarity index],
      [rename from]/[rename to], [copy from]/[copy to], [index ... <mode>], [---] and
      [+++] (["/dev/null"] is no path), and ["Binary files ... differ"].
    - Paths: from [---]/[+++] or [rename]/[copy] lines when present, else from the
      ["diff --git a/X b/Y"] line (unambiguous when X = Y, which is the case for
      mode-only and binary changes without a rename). Prefixes [a/] and [b/] are
      removed. C-quoted paths (a double-quoted name with backslash escapes, which
      git still uses for names containing a double quote, a backslash or control
      bytes even with core.quotepath=false) are unquoted.
    - ["* Unmerged path X"] (git's [diff] for a conflicted path it cannot show,
      e.g. deleted on one side, and [diff --cached] for every conflicted path) is a
      file of its own: [change = Unmerged], both paths [X] (unquoted), [header] that
      line, no hunks, not combined.
    - [submodule] when either mode is [160000]; [binary] on the Binary line;
      [combined] for [--cc]/[--combined] (prefix columns = parents, hunk header
      ["@@@ ... @@@"]).
    - [change]: a combined file is [Unmerged] when its [index] line's result side is
      all zeros (the result is the work tree: a conflict); otherwise, as for any
      file, [Added]/[Deleted] from the new/deleted file mode lines, [Renamed] or
      [Copied] from their lines, else [Modified] (so a merge commit's [show] gives
      [Modified], [Added] or [Deleted] combined files).
    - Hunk lines get [old_line]/[new_line] numbers counted from the hunk header, as
      {!Diff.Line.t} documents (a combined line has no [old_line]); an empty line
      inside a hunk is a context line with empty text ([diff.suppressBlankEmpty]).
    - Per-file {!Diff.Limits}: once a file's kept hunk lines would exceed
      [file_lines] or their text bytes [file_bytes] (line texts only, as
      {!Diff.Limits.t} documents), that hunk and the rest of the file's hunks are
      dropped and counted in [truncated].
    - With [~cut:true] (stdout cut at its limit): the last file's incomplete trailing
      hunk is dropped, its [truncated] has [cut = true], and [Diff.t.cut] is set.
    A line that fits none of these (outside the preamble) is an error. *)
val parse : Diff.Limits.t -> cut:bool -> string -> Diff.t Or_error.t
