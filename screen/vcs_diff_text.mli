(** The VCS view's diff panel text (private to {!Vcs_view}): a parsed
    {!Ches_vcs.Diff.t} laid out as read-only text, one logical line per diff line, with
    each line's kind (for its style) and the file and line that [e]/Enter opens from
    it.

    Layout: a [show]'s preamble (header lines; the indented message as plain text),
    then per file its raw header lines, then its hunks (the [@@] header, then each
    line as its prefix and text). Binary, mode-only, rename-only and submodule files
    are their headers only (a submodule adds one note naming the commits its hidden
    hunk shows). An [Unmerged] file shows its combined hunks when git gave any (the
    conflict markers, which is the point of looking at a conflict) and otherwise only
    its ["* Unmerged path"] header. A truncated file ends with a placeholder naming
    what was omitted; a cut diff ends with a note.

    Texts are raw bytes from git: drawing escapes control bytes ({!Cell_map}); the
    only byte changed here is a line feed inside a line (impossible from the parser,
    but it would split a line), shown as [^J]. *)

open! Core
open Ches_vcs

module Kind : sig
  type t =
    | Preamble (** A commit's header lines ([show]). *)
    | Message (** A commit's message lines and blank lines. *)
    | Meta (** A file's header lines. *)
    | Hunk (** [@@ ... @@]. *)
    | Added
    | Removed
    | Context
    | No_newline (** ["\ No newline at end of file"]. *)
    | Note (** Placeholders and notes the view adds. *)
  [@@deriving sexp_of, equal]

  val style : t -> Style.t
end

(** Where [e]/Enter opens from a line: a file of the diff (its path relative to the
    repository root) and a line. *)
module Target : sig
  type t =
    { path : string option (** The new path; [None] for a deleted file. *)
    ; display : string (** {!Diff.File.path}, for notices. *)
    ; line : int option (** 1-based; [None] for a file header line. *)
    }
  [@@deriving sexp_of, equal]
end

module Line : sig
  type t =
    { text : string
    ; kind : Kind.t
    ; target : Target.t option (** [None] outside any file (preamble, notes). *)
    }
  [@@deriving sexp_of]
end

type t [@@deriving sexp_of]

(** Lines, in order. *)
val lines : t -> Line.t list

(** The lines joined by line feeds. *)
val text : t -> string

val of_diff : Diff.t -> t

(** One note line (["No diff for this row"], a failure). *)
val of_message : string -> t

(** The line containing byte [offset] of {!text}. *)
val line_at : t -> int -> Line.t option

(** Where a line came from in the {!Diff.t} it was laid out from ({!of_diff}): what
    the VCS view's hunk actions (phase 3) and line selections (phase 4) act on. *)
module Position : sig
  type t =
    { file : int (** Index into [Diff.t.files]. *)
    ; hunk : int option
    (** Index into that file's [hunks]; [None] for its header lines, a submodule's
        note and the truncation placeholder. *)
    ; line : int option
    (** Index into that hunk's [lines]; [None] for the [@@] header line. *)
    }
  [@@deriving sexp_of, equal]
end

(** The position of the line containing byte [offset]; [None] outside any file (a
    commit's preamble, the cut note, an {!of_message} text). *)
val position_at : t -> int -> Position.t option

(** The byte offset of a file's first line ([hunk = None]) or of a hunk's [@@] line;
    [None] when it is not laid out (out of range, or a header-only file's hunks). *)
val start_of : t -> file:int -> hunk:int option -> int option

(** The byte offsets of every [@@] line, in order ([\]] and [\[] in the view). *)
val hunk_starts : t -> int list

(** The kind of the line starting at byte [offset], if one starts there. *)
val kind_at_start : t -> int -> Kind.t option
