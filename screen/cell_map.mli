(** {!Ches_core.Cell_layout} with the widths the terminal draws with.

    Drawing, clipping, cursor placement, and scrolling all go through {!glyphs}, and
    the editor is created with {!width}, so the screen and editing semantics agree on
    where every code point lands. Document lines, filenames, and messages all use it.

    Widths come from [Notty.Tty_width_hint], per code point. Notty measures grapheme
    clusters, so its width for a complex cluster, such as an emoji ZWJ sequence, can
    differ from the sum of ours; the frontend forces every drawn span to the width
    computed here. *)

open! Core

(** [Notty.Tty_width_hint.tty_width_hint]. Pass it to [Editor.create]. *)
val width : Ches_core.Cell_layout.Width.t

val tab_stop : int

module Kind = Ches_core.Cell_layout.Kind
module Glyph = Ches_core.Cell_layout.Glyph

(** [Cell_layout.glyphs ~width]. *)
val glyphs : string -> Glyph.t array

val total_width : Glyph.t array -> int
val cursor_span : Glyph.t array -> pos:int -> insertion:bool -> int * int
