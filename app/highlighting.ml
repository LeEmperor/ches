open! Core
open Ches_core
open Ches_highlight

module Provider = Ches_highlight_ocaml.Provider

type runtime =
  { mutable provider : Provider.t option
  ; mutable language : Language.t
  ; mutable failed : bool
  ; mutable parse_count : int
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
      ~language ~configuration:Provider.configuration
  in
  if not reset && Snapshot.Key.equal t.key key then t
  else if Language.equal language Plain then (
    close t;
    t.runtime.language <- Plain;
    t.runtime.failed <- false;
    { t with key; snapshot = Snapshot.create ~key ~source:"" []; status = None })
  else (
    if reset || t.runtime.failed || not (Language.equal t.runtime.language language)
    then close t;
    let provider =
      match t.runtime.provider with
      | Some provider -> provider
      | None ->
        let provider = Provider.create ~language in
        t.runtime.provider <- Some provider;
        t.runtime.language <- language;
        t.runtime.failed <- false;
        provider
    in
    let before = Provider.parse_count provider in
    let result = Provider.highlight provider ~key ~source:(Text_buffer.to_string (Editor.text editor)) in
    t.runtime.parse_count <- t.runtime.parse_count + Provider.parse_count provider - before;
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
    ; runtime = { provider = None; language = Plain; failed = false; parse_count = 0 }
    ; language_override = None
    }
  in
  update t editor ~reset:true
;;

let snapshot t = t.key, t.snapshot
let status t = t.status
let parse_count t = t.runtime.parse_count

module For_testing = struct
  let with_language t editor language =
    update { t with language_override = Some language } editor ~reset:true
  ;;
  let fail_next_parse t =
    Option.iter t.runtime.provider ~f:Provider.For_testing.fail_next_parse
  ;;
end
