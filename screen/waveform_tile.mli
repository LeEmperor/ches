open! Core

(** Native, read-only floating waveform, independent of terminal/Async loops.
    Inspired by hardcaml_waveterm's signal/value/time-pane separation; no upstream
    implementation is copied. Integer ticks preserve the VCD's declared scale.
    [:] marks activity compressed into a column, [~] visibly clips names/values. *)
type t [@@deriving sexp_of]
val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
val create : Ches_harness.Vcd.t -> Ches_harness.Protocol.run -> string -> t
val key : t -> Ches_input.Key.t -> width:int -> rows:int -> t
val render : t -> width:int -> rows:int -> Tile_shell.Content.t
