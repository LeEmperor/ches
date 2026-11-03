open Ches_config

(* These are the built-in defaults. Keep only the settings you want to change.
   Palette/keybinding changes are session-only. Reload configuration rebuilds
   supported defaults and executes this file again. *)
let () =
  Completion.set_enabled true;
  Completion.set_ghost_preview false;
  Completion.set_min_prefix_chars 1;
  Completion.set_prefer_local_snippets true;
  View.set_line_numbers false;
  Theme.set "vim-classic"

(* Snippets.add and Snippets.disable can follow here; see snippets.example.ml.
   Reload configuration validates settings and snippets together. *)
