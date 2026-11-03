open Ches_config

(* These are the built-in defaults. Keep only the settings you want to change.
   Palette/keybinding changes are session-only. Reload configuration rebuilds
   supported defaults and executes this file again. *)
let () =
  Completion.set_enabled true;
  Completion.set_ghost_preview false;
  Completion.set_min_prefix_chars 1;
  Completion.set_prefer_local_snippets true;
  Signature_help.set_enabled true;
  View.set_line_numbers false;
  Theme.set "vim-classic"

(* Optional completion-menu overrides (otherwise colors follow the theme):
   let () =
     Completion.set_color ~role:"selected_background" "#283447";
     Completion.set_color ~role:"detail" "#b8d7a3";
     Completion.set_color ~role:"selected_detail" "#c9e8b4"
*)

(* All snippet collections are enabled by default. For example:
   let () =
     Snippets.set_collection_enabled ~collection:"hardcaml" false;
     Snippets.set_collection_enabled ~collection:"hardcaml.design" true

   Snippets.add and Snippets.disable can follow here; see snippets.example.ml.
   Reload configuration validates settings and snippets together. *)
