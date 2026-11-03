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

module Snippets = struct
  type declaration =
    { id : string
    ; prefix : string
    ; scopes : string list
    ; collection : string option
    ; description : string option
    ; body : string
    }
  type operation = Add of declaration | Disable of string
    | Set_collection_enabled of { collection : string; enabled : bool }
  let operations = ref []
  let count = ref 0
  let record operation =
    if !count >= 1000 then invalid_arg "snippets exceeds 1000 operations";
    incr count;
    operations := operation :: !operations
  let add ~id ~prefix ?(scope = []) ?collection ?description body =
    record (Add { id; prefix; scopes = scope; collection; description; body })
  let disable ~id = record (Disable id)
  let set_collection_enabled ~collection enabled =
    record (Set_collection_enabled { collection; enabled })
end

let write_result path =
  (* Count bytes before allocating or writing the result. Hex protects all OCaml
     strings (including newlines) without adding any helper dependencies. *)
  let buffer = Buffer.create 1024 in
  let limit = 1024 * 1024 in
  let reserve length =
    if length > limit - Buffer.length buffer then
      invalid_arg "settings result exceeds 1 MiB"
  in
  let line value =
    reserve (String.length value + 1);
    Buffer.add_string buffer value;
    Buffer.add_char buffer '\n'
  in
  let hex value =
    reserve 1;
    if String.length value > (limit - Buffer.length buffer - 1) / 2 then
      invalid_arg "settings result exceeds 1 MiB";
    let digits = "0123456789abcdef" in
    String.iter (fun c ->
      let n = Char.code c in
      Buffer.add_char buffer digits.[n lsr 4];
      Buffer.add_char buffer digits.[n land 15]) value;
    Buffer.add_char buffer '\n'
  in
  let number n = line (string_of_int n) in
  let operations = List.rev !(Snippets.operations) in
  if List.length operations > 1000 then invalid_arg "snippets exceeds 1000 operations";
  line "CHES_SETTINGS_3";
  List.iter (fun value -> line (string_of_bool value)) [!enabled; !ghost_preview];
  number !min_prefix_chars;
  List.iter (fun value -> line (string_of_bool value)) [!prefer_local_snippets; !line_numbers];
  hex !theme;
  number (List.length operations);
  List.iter (function
    | Snippets.Disable id -> line "disable"; hex id
    | Snippets.Set_collection_enabled { collection; enabled } ->
      line "collection"; hex collection; line (string_of_bool enabled)
    | Snippets.Add declaration ->
      line "add";
      hex declaration.id;
      hex declaration.prefix;
      number (List.length declaration.scopes);
      List.iter hex declaration.scopes;
      (match declaration.collection with
       | None -> line "none"
       | Some value -> line "some"; hex value);
      (match declaration.description with
       | None -> line "none"
       | Some value -> line "some"; hex value);
      hex declaration.body) operations;
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
    output_string channel (Buffer.contents buffer))
