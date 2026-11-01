(** The commit graph of the Commits panel (phase 8), drawn lazygit's way: one row per
    commit, no connector-only rows, computed from each commit's parents alone. Pure
    and backend-agnostic: commits are ids with parent ids, newest first, in an order
    where a commit comes before its parents (git's [--topo-order]).

    {2 Lanes}

    A lane is a column waiting for one commit. For each commit in order:
    + Its lane is the leftmost lane waiting for it; if none waits, the leftmost free
      lane (free before this row), else a new lane on the right.
    + Every other lane waiting for it ends on this row, joining it.
    + Its lane then waits for its first parent (is freed for a root commit).
    + Each further parent: if a lane already waits for it (other than the commit's
      own), the commit joins that lane; otherwise it starts a new lane in the
      leftmost lane free before this row (lanes ended on this row are not reused
      until the next), else a new lane on the right.
    + Free lanes at the right end are dropped.
    A parent that never appears (beyond the list's limit) keeps its lane to the end.

    {2 Glyphs}

    A row has two characters per lane, from lane 0 to the rightmost lane in use
    before or after the row: the lane's glyph, then a gap. Glyphs:
    - the commit: ["●"];
    - a lane waiting for another commit before and after the row: ["│"], or ["┼"]
      where a horizontal line crosses it;
    - a lane ending here (joining the commit): ["╯"] right of the commit, ["╰"] left;
    - a lane starting here (a further parent): ["╮"] right, ["╭"] left;
    - a lane already waiting for a further parent, which the commit joins: ["┤"]
      right, ["├"] left (the lane continues);
    - otherwise ["  "] (a free lane).
    Between the commit and each lane it ends, starts or joins, every gap and free
    lane is ["─"]. Other gaps are spaces. So a merge of a side branch reads
    ["●─╮ "], the side branch's commits ["│ ● "], and its fork point ["●─╯ "]. *)

open! Core

(** One row per commit of [commits] (id, parent ids), in the same order. Rows are
    UTF-8; [max_width] (default 24) counts characters: a longer row is cut to its
    first [max_width - 2] characters followed by ["… "]. Duplicate ids: the later
    ones are drawn as commits nothing waits for. *)
val rows : ?max_width:int -> (string * string list) list -> string list
