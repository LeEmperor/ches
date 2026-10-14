open! Core
open Ches_core
open Ches_highlight

module Provider = Ches_highlight_tree_sitter.Provider

module Policy = struct
  let max_bytes = 64 * 1024
  let max_lines = 2000
  let max_captures = 16000
end

type runtime =
  { mutable provider : Provider.t option
  ; mutable language : Language.t
  ; mutable failed : bool
  ; mutable parse_count : int
  ; mutable incremental_count : int
  ; mutable capture_block : (int * int) option
  }

type t =
  { document : Snapshot.Document_id.t
  ; key : Snapshot.Key.t
  ; snapshot : Snapshot.t
  ; status : Provider.Status.t option
  ; runtime : runtime
  ; language_override : Language.t option
  }

let close t =
  Option.iter t.runtime.provider ~f:Provider.close;
  t.runtime.provider <- None
;;

let update t editor ~reset =
  let language =
    Option.value t.language_override ~default:(Language.of_path (Editor.path editor))
  in
  let key =
    Snapshot.Key.create ~document:t.document ~revision:(Editor.revision editor)
      ~language ~configuration:(Provider.configuration_for_language language)
  in
  if not reset && Snapshot.Key.equal t.key key then t
  else (
    if reset || not (Language.equal t.runtime.language language) then (
      close t;
      t.runtime.capture_block <- None);
    t.runtime.language <- language;
    let text = Editor.text editor in
    let bytes = Text_buffer.length text and lines = Text_buffer.line_count text in
    (* A deterministic density failure stays blocked across tiny edits. Retry
       after a substantial shrink, explicit reload/reset or language change. *)
    if Option.exists t.runtime.capture_block ~f:(fun (old_bytes, old_lines) ->
      bytes <= old_bytes * 3 / 4 || lines <= old_lines * 3 / 4)
    then t.runtime.capture_block <- None;
    let fallback =
      if bytes > Policy.max_bytes then Some (Provider.Failure.Source_byte_limit Policy.max_bytes)
      else if lines > Policy.max_lines then Some (Provider.Failure.Source_line_limit Policy.max_lines)
      else Option.map t.runtime.capture_block ~f:(fun _ -> Provider.Failure.Capture_limit Policy.max_captures)
    in
    if Language.equal language Plain then (
      close t;
      t.runtime.failed <- false;
      { t with key; snapshot = Snapshot.create ~key ~source:"" []; status = None })
    else match fallback with
    | Some failure ->
      close t;
      t.runtime.failed <- false;
      { t with key; snapshot = Snapshot.create ~key ~source:"" []; status = Some (Plain failure) }
    | None ->
      if t.runtime.failed then close t;
      let provider =
        match t.runtime.provider with
        | Some provider -> provider
        | None ->
          let provider = Provider.create ~language in
          t.runtime.provider <- Some provider;
          t.runtime.failed <- false;
          provider
      in
      let before = Provider.parse_count provider in
      let incremental_before = Provider.incremental_count provider in
      let result = Provider.highlight_incremental ~max_captures:Policy.max_captures
          provider ~key ~source:(Text_buffer.to_string text) in
      t.runtime.parse_count <- t.runtime.parse_count + Provider.parse_count provider - before;
      t.runtime.incremental_count <- t.runtime.incremental_count + Provider.incremental_count provider - incremental_before;
      (match result.status with
       | Plain (Capture_limit _) ->
         t.runtime.capture_block <- Some (bytes, lines);
         close t
       | _ -> ());
      t.runtime.failed <-
        (match result.status with
         | Plain _ -> true
         | Highlighted _ -> false);
      { t with key; snapshot = result.snapshot; status = Some result.status })
;;

let create editor =
  let document = Snapshot.Document_id.create () in
  let key =
    Snapshot.Key.create ~document ~revision:(Editor.revision editor)
      ~language:Plain ~configuration:Provider.configuration
  in
  let t =
    { document
    ; key
    ; snapshot = Snapshot.create ~key ~source:"" []
    ; status = None
    ; runtime = { provider = None; language = Plain; failed = false; parse_count = 0; incremental_count = 0; capture_block = None }
    ; language_override = None
    }
  in
  update t editor ~reset:true
;;

let snapshot t = t.key, t.snapshot
let status t = t.status
let parse_count t = t.runtime.parse_count

module For_testing = struct
  let has_live_provider t = Option.is_some t.runtime.provider
  let incremental_count t = t.runtime.incremental_count
  let with_language t editor language =
    update { t with language_override = Some language } editor ~reset:true
  ;;
  let fail_next_parse t =
    Option.iter t.runtime.provider ~f:Provider.For_testing.fail_next_parse
  ;;
end
