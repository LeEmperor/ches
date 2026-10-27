(** A parsed diff, as the diff panel shows it and later phases act on it: files, each
    with the raw header lines and hunks of a unified (or combined) diff. Backends
    parse their tool's output into this ([Ches_vcs_git.Diff_output] for git's
    [diff], [diff --cached] and [show]). Texts are raw bytes without line
    terminators; display escaping is the view's job.

    Diffs are bounded per file ({!Limits}): hunks past a limit are dropped whole and
    counted in {!File.truncated}, so every hunk kept is complete and can still be
    turned into a patch (phases 3 and 4). *)

open! Core

module Line : sig
  module Kind : sig
    type t =
      | Context
      | Added
      | Removed
      | No_newline (** ["\ No newline at end of file"], about the line before it. *)
    [@@deriving sexp, equal]
  end

  type t =
    { kind : Kind.t
    ; prefix : string
    (** The marker columns as they appeared: one character in a unified diff ([" "],
        ["+"], ["-"], ["\\"]), one per parent in a combined diff (["+ "], [" -"]). In a
        combined diff a line is [Added] if any column is ['+'], [Removed] if any is
        ['-'], else [Context]. *)
    ; text : string (** After the prefix. *)
    ; old_line : int option
    (** 1-based line in the old side ([Context] and [Removed] of a unified diff).
        Always [None] in a combined diff, which has one old side per parent. *)
    ; new_line : int option
    (** 1-based line in the new side ([Context] and [Added]): in a combined diff, the
        result (git's work-tree file for a conflict), counted from the hunk's
        [new_start] over the lines not [Removed] from it. [None] for [Removed] and
        [No_newline]. *)
    }
  [@@deriving sexp, equal]
end

module Hunk : sig
  type t =
    { header : string (** The raw ["@@ -a,b +c,d @@ section"] (or ["@@@ ..."]) line. *)
    ; old_start : int
    ; old_count : int
    (** [-a] alone means a count of 1. For a combined diff: the first parent's. *)
    ; new_start : int
    ; new_count : int
    ; section : string (** Text after the closing [@@], without the leading space. *)
    ; lines : Line.t list
    }
  [@@deriving sexp, equal]
end

module File : sig
  module Change : sig
    type t =
      | Added
      | Deleted
      | Modified (** Including a mode-only change. *)
      | Renamed of { similarity : int option } (** Percent. *)
      | Copied of { similarity : int option }
      | Type_changed (** e.g. a file became a symlink (git shows delete + add). *)
      | Unmerged
      (** A conflicted path: a combined diff whose result is the work tree (its index
          line's result side is all zeros), or git's ["* Unmerged path X"] line,
          which has no hunks. A merge commit's combined diff ([show]) is [Modified],
          [Added] or [Deleted] instead. *)
    [@@deriving sexp, equal]
  end

  module Truncated : sig
    type t =
      { omitted_hunks : int (** Hunks dropped after the last one kept. *)
      ; omitted_lines : int (** Their lines; a lower bound if [cut] is set. *)
      ; cut : bool
      (** The command's output itself ended inside this file (its stdout limit), so
          the counts are not totals. *)
      }
    [@@deriving sexp, equal]
  end

  type t =
    { old_path : string option (** [None] for an added file. *)
    ; new_path : string option (** [None] for a deleted file. *)
    ; change : Change.t
    ; old_mode : string option (** e.g. ["100644"], when the header names it. *)
    ; new_mode : string option
    ; header : string list
    (** Every line from the file's first header line (git's ["diff --git ..."]) up to
        its first hunk, verbatim, so a patch can be rebuilt. *)
    ; hunks : Hunk.t list
    ; binary : bool (** ["Binary files ... differ"]; no hunks. *)
    ; submodule : bool
    (** A gitlink (mode [160000]) on either side: hunks show commit ids, not
        content. *)
    ; combined : bool (** A combined ([--cc]) diff: one prefix column per parent. *)
    ; truncated : Truncated.t option
    }
  [@@deriving sexp, equal]

  (** [new_path], else [old_path]. *)
  val path : t -> string

  (** Only the mode changed: [Modified], both modes known and different, no hunks,
      not binary. *)
  val mode_only : t -> bool

  (** Renamed or copied with no content change: no hunks, not binary. *)
  val rename_only : t -> bool

  (** Whether hunk and line actions (phases 3 and 4) may apply to it: not binary,
      submodule, combined, [Unmerged], mode-only or rename-only. Such files render as
      headers without line actions. A truncated file's kept hunks remain
      actionable. *)
  val line_actions : t -> bool
end

module Limits : sig
  type t =
    { file_lines : int (** Hunk lines kept per file. *)
    ; file_bytes : int
    (** Hunk line bytes kept per file, counting each line's [text] only: not its
        prefix, its terminator, or the hunk and file headers. *)
    }
  [@@deriving sexp, equal]

  (** 2000 lines, 256 KiB. *)
  val default : t
end

type t =
  { preamble : string list
  (** Lines before the first file: a commit's header and message for [show]; empty
      for a plain diff. *)
  ; files : File.t list
  ; cut : bool (** The command's output was cut at its stdout limit. *)
  }
[@@deriving sexp, equal]

val empty : t
