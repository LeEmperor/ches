open! Core
open Ches_core

(** Lexically normalized startup classification; missing paths remain file targets. *)
type kind = File | Directory
val classify : string -> kind
(** Validate directory readability before starting the terminal frontend. The session
    adopts directory startup as a directory buffer, never as a persistent file tab. *)
val open_path : ?keymap_config:Ches_input.Keymap.Config.t -> cell_width:Cell_layout.Width.t -> string -> Controller.t Or_error.t
