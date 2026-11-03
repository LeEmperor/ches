(* This exact Stdlib-only source is embedded in the editor and compiled alongside
   each user configuration. It has no dependency on an installed Ches library. *)
let enabled = ref true
let ghost_preview = ref false
let min_prefix_chars = ref 1
let prefer_local_snippets = ref true
let line_numbers = ref false
let theme = ref "vim-classic"

module Completion = struct
  let set_enabled value = enabled := value
  let set_ghost_preview value = ghost_preview := value
  let set_min_prefix_chars value =
    if value < 1 then invalid_arg "completion_min_prefix_chars must be positive";
    min_prefix_chars := value
  let set_prefer_local_snippets value = prefer_local_snippets := value
end

module View = struct
  let set_line_numbers value = line_numbers := value
end

module Theme = struct
  let set value =
    if String.trim value = "" then invalid_arg "theme must be nonempty";
    theme := value
end

let write_result path =
  if String.length !theme > (1024 * 1024 - 128) / 2 then
    invalid_arg "settings result exceeds 1 MiB";
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
    Printf.fprintf channel "CHES_SETTINGS_1\n%b\n%b\n%d\n%b\n%b\n"
      !enabled !ghost_preview !min_prefix_chars !prefer_local_snippets !line_numbers;
    String.iter (fun c -> Printf.fprintf channel "%02x" (Char.code c)) !theme;
    output_char channel '\n')
