(** Frontend commands for layout, scrolling and file-tab lifetime. Layout commands
    change preferences without editing; tab commands use session policy rather than
    document-local effects. Terminal-independent, like the rest of [ches_input]. *)

open! Core

(** Scrolling the view. Unlike the other view commands, these may move the cursor, but
    only to keep it in view, and never edit. *)
module Scroll : sig
  type t =
    | Line_down (** [Ctrl-e]: the view down by one line, or by a count. *)
    | Line_up (** [Ctrl-y]: the view up by one line, or by a count. *)
    | Half_page_down
    (** [Ctrl-d]: the view and cursor down half the viewport, or by a count. *)
    | Half_page_up
    (** [Ctrl-u]: the view and cursor up half the viewport, or by a count. *)
    | Cursor_middle (** [zz]: the cursor line to the middle of the viewport. *)
    | Cursor_top (** [zt]: the cursor line to the top of the viewport. *)
    | Cursor_bottom (** [zb]: the cursor line to the bottom of the viewport. *)
  [@@deriving sexp_of, equal, enumerate]

  (** All but [Cursor_middle], [Cursor_top], and [Cursor_bottom]. *)
  val takes_count : t -> bool
end

module Status_position : sig
  type t =
    | Left
    | Right
    | Above
    | Below
  [@@deriving sexp_of, equal]
end

module Buffer_presentation : sig
  type t = Top | Status_rows [@@deriving sexp_of, equal]
end

(** Where a registered view is shown. A view has exactly one placement at a time. *)
module Placement : sig
  type t =
    | Hidden (** Closed. The view keeps its state, and is shown again where asked. *)
    | Band (** The bottom band of minor views. *)
    | Tab
    (** An entry in the tab strip, added after the active entry; while active it fills
        the editor area. *)
    | Split (** The major split: a peer pane beside the active tab. At most one view. *)
  [@@deriving sexp_of, equal]
end

type t =
  | Toggle_directory
  | Directory_major
  | Directory_side
  | Hide_directory
  | Focus_directory
  | Adjust_directory_size of int
  | Open_directory_entry
  | Directory_parent
  | Refresh_directory
  | Toggle_entry_mark
  | Mark_selection
  | Unmark_selection
  | Clear_directory_marks
  | Open_marked_files
  | Next_tab (** Activate the next file tab, wrapping in open order. *)
  | Previous_tab (** Activate the previous file tab, wrapping in open order. *)
  | Present_buffers of Buffer_presentation.t
  (** Requested file-buffer presentation. Status rows fall back to the top strip
      when status is hidden/unavailable; zen suppresses both. *)
  | Close_tab (** Close the current file; refuse unsaved changes. *)
  | Force_close_tab (** Explicitly discard the current file's unsaved changes. *)
  | Recreate_missing_file (** Exclusive explicit recovery; ordinary save refuses. *)
  | Toggle_centered (** Switch between the centered tile and full width. *)
  | Shift of int
  (** Move the centered tile by this many display cells; negative is left. *)
  | Adjust_width of int (** Change the preferred text width by this many display cells. *)
  | Toggle_absolute_numbers
  (** Flip the absolute line-number switch (Vim's ['number']). *)
  | Toggle_relative_numbers
  (** Flip the relative line-number switch (Vim's ['relativenumber']). *)
  | Toggle_smear (** Enable or disable the animated terminal cursor. *)
  | Toggle_status (** Show/hide the requested status cell, independent of zen. *)
  | Toggle_hotkey_hints (** Show/hide tile hotkey hints; hidden by default. *)
  | Position_status of Status_position.t (** Place status and request visibility. *)
  | Adjust_status_size of int (** Adjust requested status cells along its split axis. *)
  | Inspect_problems (** Cycle retained problem details, without retrying. *)
  | Toggle_problems_filter (** Workspace/current-document preview filter. *)
  | Toggle_view of View_id.t
  (** Show a hidden registered view (problems, history, the demo report, ...) in the
      bottom band, or hide (close) it from any placement. A view that is not
      installed only reports why. *)
  | Focus_view of View_id.t
  (** Show/focus a registered view, or return to the document when it is focused. A
      hidden view is shown in the band; a view tab is activated, and when it is
      already the focused active tab, the active file tab is shown instead. *)
  | Place_view of
      { view : View_id.t option (** [None]: the focused registered view. *)
      ; placement : Placement.t
      }
  (** Move a registered view out of its placement into [placement]. [Tab] and
      [Split] also focus it; a view already in the split is closed by another's
      arrival. [Hidden] closes it. *)
  | Focus_other_pane
  (** In the major split, focus the split view, or return to the active tab when it
      is focused. *)
  | Swap_split (** Put the split view on the other side of the editor area. *)
  | Adjust_split of int
  (** Change the split view's requested share of the editor area, in percent. *)
  | Close_split
  (** Close the split view from either pane, as [Place_view] to [Hidden] would, even
      while zen or a narrow editor area keeps it from being shown. Focus in it
      returns to the active tab. With no split view, only says so. *)
  | Run_view_command of
      { view : View_id.t
      ; command : string (** A name the view declares among its local commands. *)
      }
  (** Run one of a focused view's local commands, as its keys would. Refused, with a
      notice, unless [view] is focused and currently declares [command]. *)
  | Restart_source (** Restart the diagnostic source ([--synthetic-checker]). *)
  | Kill_source (** Crash the synthetic diagnostic source, to test the stopped state. *)
  | Toggle_zen (** Hide status temporarily, or restore saved workspace intent. *)
  | Open_palette (** Open the command palette for the document. *)
  | Open_line_picker (** Fuzzy search the current in-memory document's lines. *)
  | Open_file_picker (** Find and open an existing project file. *)
  | Open_content_picker (** Search project contents on disk literally. *)
  | Reset (** Centered, at the default width and offset, with line numbers off. *)
  | Scroll of
      { scroll : Scroll.t
      ; count : int option
      (** [None] when none was given; only when [Scroll.takes_count]. *)
      }
[@@deriving sexp_of, equal]

(** [scale t ~count] repeats a resize step [count] times, for a Normal-mode count:
    [Shift], [Adjust_width], [Adjust_split], [Adjust_status_size], and
    [Adjust_directory_size] with their step multiplied by [count] (positive, at most
    [Command.max_count]). Each result is clamped where it is applied, like repeated
    presses. [None] for every other command, which takes no count ([Scroll] carries
    its own). *)
val scale : t -> count:int -> t option
