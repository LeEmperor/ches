(** Conflict regions that a merge left in a text as markers, found as pure functions
    of the text, with no knowledge of the tool that wrote them.

    {2 Markers}

    A region is four kinds of marker line, in this order:

    {v
      <<<<<<< HEAD               start: the upper side follows
      ...
      ||||||| merged ancestors   base (optional): the base part follows
      ...
      =======                    separator: the lower side follows
      ...
      >>>>>>> feature            end
    v}

    - The start, base and end lines begin with exactly seven [<], [|] or [>],
      followed by a space or the line end. The label is the rest of the line after
      that space, possibly empty or containing spaces.
    - The separator line is exactly seven [=] and nothing else.
    - Only this marker size (git's default [conflict-marker-size] of 7) is
      recognised: a line of eight [<] starts nothing.

    Lines are scanned top to bottom. A start line always begins a new region, so a
    start line before the end of the current one abandons it and starts over. A
    region is ignored when it is unterminated (the text ends first) or malformed: an
    end line before the separator, a second base line, or a base or separator line
    after the separator. Marker lines outside a region are ordinary text.

    Every side's lines lie strictly between marker lines, so each ends with LF. *)

open! Core

module Side : sig
  (** What to keep of a region, in smerge's terms. In a merge the upper side is
      ours (HEAD, the branch merged into) and the lower is theirs (the branch being
      merged). While rebasing they swap: the upper side is the upstream being
      rebased onto, and the lower is your commit being applied. *)
  type t =
    | Upper (** The lines after the start line. *)
    | Lower (** The lines after the separator. *)
    | Both (** The upper lines, then the lower ones. *)
    | Base
    (** The lines after the base line: the common ancestor's version, present with
        [merge.conflictStyle=diff3] or [zdiff3]. *)
  [@@deriving sexp_of, equal, enumerate]

  (** Lowercase, for feedback: ["upper"], ["lower"], ["both"], ["base"]. *)
  val to_string : t -> string
end

module Region : sig
  (** One region, by zero-based line indices of its marker lines. *)
  type t =
    { start : int (** The [<<<<<<<] line. *)
    ; base : int option (** The [|||||||] line, if any. *)
    ; separator : int (** The [=======] line. *)
    ; stop : int (** The [>>>>>>>] line, the region's last. *)
    ; upper_label : string
    ; base_label : string (** Empty without a base line. *)
    ; lower_label : string
    }
  [@@deriving sexp_of, equal]

  (** The lines that keeping [side] leaves in place of the region, in order and
      possibly none; [None] for [Base] when the region has no base line. *)
  val lines : t -> Side.t -> int list option
end

(** Every region of the text, top to bottom. Linear in the text. *)
val regions : Text_buffer.t -> Region.t list

(** The region whose lines, markers included, contain [line]. *)
val region_at : Text_buffer.t -> line:int -> Region.t option
