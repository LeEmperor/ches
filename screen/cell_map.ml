open! Core
include Ches_core.Cell_layout

let width = Notty.Tty_width_hint.tty_width_hint
let glyphs s = glyphs ~width s
