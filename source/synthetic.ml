open! Core
open! Async
module Feedback = Ches_error.Error
module Source_event = Ches_error.Source_event
module Finding = Feedback.Diagnostics.Finding

module Config = struct
  type t =
    { edit_delay : Time_ns.Span.t
    ; build_delay : Time_ns.Span.t
    }

  let default =
    { edit_delay = Time_ns.Span.of_int_ms 400; build_delay = Time_ns.Span.of_int_ms 800 }
  ;;
end

let source = "synthetic"
let other_file ~resource = Filename.concat (Filename.dirname resource) "synthetic_other.ml"

let findings text ~f =
  (* The empty line after a final newline is not a line of the document. *)
  let lines = String.split text ~on:'\n' in
  let lines =
    match List.rev lines with
    | "" :: rest when not (List.is_empty rest) -> List.rev rest
    | _ -> lines
  in
  List.filter_mapi lines ~f:(fun i line ->
    Option.map (f line) ~f:(fun (severity, message) : Finding.t ->
      { severity; message; location = Some { line = i + 1; column = 1 } }))
;;

let edit_findings =
  findings ~f:(fun line ->
    if String.is_substring line ~substring:"ERROR"
    then Some (Feedback.Severity.Error, "synthetic error: the line contains ERROR")
    else if String.is_substring line ~substring:"TODO"
    then Some (Warning, "synthetic warning: unfinished TODO")
    else None)
;;

let build_findings =
  findings ~f:(fun line ->
    Option.some_if
      (String.is_substring line ~substring:"ERROR")
      (Feedback.Severity.Error, "synthetic build error: ERROR does not compile"))
;;

let other_findings : Finding.t list =
  [ { severity = Warning
    ; message = "synthetic build warning: unused value in a file you have not opened"
    ; location = Some { line = 3; column = 1 }
    }
  ]
;;

module Document = struct
  type t =
    { resource : string
    ; revision : int
    ; text : string
    }
end

type state =
  { root : string
  ; config : Config.t
  ; time_source : Time_source.t
  ; emit : Source_event.t -> unit
  ; mutable running : bool
  ; mutable session : int (** Increased by a kill or restart: older timers do nothing. *)
  ; mutable latest : Document.t option
  ; mutable saved : (string * string) option (** Resource and text on disk. *)
  ; mutable edit_scheduled : bool
  ; mutable build_scheduled : bool
  ; mutable checked : (string * int * Finding.t list) option
  (** This session's newest edit check: resource, revision, findings. *)
  ; mutable built : (string * Finding.t list) option
  (** This session's newest build of the open file: resource, findings. *)
  }

(* Runs [f] after [delay] unless the session ended meanwhile. *)
let after state delay ~f =
  let session = state.session in
  Time_source.run_after
    state.time_source
    delay
    (fun () -> if state.running && state.session = session then f ())
    ()
;;

(* The open file's list merges both checks, as a language server merges its own; it
   describes the revision of the edit check it includes. *)
let publish state ~resource =
  let checked =
    Option.filter state.checked ~f:(fun (checked, _, _) -> String.equal checked resource)
  in
  let built =
    Option.value_map state.built ~default:[] ~f:(fun (built, findings) ->
      if String.equal built resource then findings else [])
  in
  state.emit
    (Diagnostics
       { source
       ; resource
       ; revision = Option.map checked ~f:(fun (_, revision, _) -> revision)
       ; findings = Option.value_map checked ~default:[] ~f:(fun (_, _, f) -> f) @ built
       })
;;

let report_edit state =
  state.edit_scheduled <- false;
  Option.iter state.latest ~f:(fun { resource; revision; text } ->
    state.checked <- Some (resource, revision, edit_findings text);
    publish state ~resource)
;;

let report_build state =
  state.build_scheduled <- false;
  Option.iter state.saved ~f:(fun (resource, text) ->
    state.built <- Some (resource, build_findings text);
    publish state ~resource;
    state.emit
      (Diagnostics
         { source; resource = other_file ~resource; revision = None; findings = other_findings }))
;;

(* One pending check of each kind: changes made while it waits are picked up when it
   runs, so it reports the newest text (and a revision older than the editor's, while
   typing continues). *)
let schedule_edit state =
  if state.running && (not state.edit_scheduled) && Option.is_some state.latest
  then (
    state.edit_scheduled <- true;
    after state state.config.edit_delay ~f:(fun () -> report_edit state))
;;

let schedule_build state =
  if state.running && (not state.build_scheduled) && Option.is_some state.saved
  then (
    state.build_scheduled <- true;
    after state state.config.build_delay ~f:(fun () -> report_build state))
;;

(* A new session: timers of the old one lapse, its results are forgotten, and both
   checks run again. *)
let begin_session state =
  state.session <- state.session + 1;
  state.running <- true;
  state.edit_scheduled <- false;
  state.build_scheduled <- false;
  state.checked <- None;
  state.built <- None;
  state.emit (Started { source; root = state.root });
  schedule_edit state;
  schedule_build state
;;

let handle state (request : Ches_error.Source_request.t) =
  match request with
  | Document_changed { resource; text; revision } ->
    state.latest <- Some { resource; revision; text };
    (* Before any save, the text first sent is what is on disk. *)
    if Option.is_none state.saved
    then (
      state.saved <- Some (resource, text);
      schedule_build state);
    schedule_edit state
  | Document_saved { resource; revision = _ } ->
    Option.iter state.latest ~f:(fun latest ->
      if String.equal latest.resource resource
      then state.saved <- Some (resource, latest.text));
    schedule_build state
  | Kill ->
    if state.running
    then (
      state.running <- false;
      state.session <- state.session + 1;
      state.emit
        (Stopped
           { source; root = state.root; reason = "killed by Space v K (synthetic crash)" }))
  | Restart -> begin_session state
;;

let start ?(config = Config.default) ?(time_source = Time_source.wall_clock ()) ~root () =
  Source.create (fun ~emit ->
    let state =
      { root
      ; config
      ; time_source
      ; emit
      ; running = false
      ; session = 0
      ; latest = None
      ; saved = None
      ; edit_scheduled = false
      ; build_scheduled = false
      ; checked = None
      ; built = None
      }
    in
    begin_session state;
    { handle = handle state
    ; stop =
        (fun () ->
          state.running <- false;
          state.session <- state.session + 1)
    })
;;

module Script = struct
  type step =
    | Wait of Time_ns.Span.t
    | Emit of Source_event.t

  let play ?(time_source = Time_source.wall_clock ()) steps =
    Source.create (fun ~emit ->
      let stopped = ref false in
      let rec run = function
        | [] -> ()
        | _ when !stopped -> ()
        | Emit event :: rest ->
          emit event;
          run rest
        | Wait span :: rest -> Time_source.run_after time_source span run rest
      in
      run steps;
      { handle = ignore; stop = (fun () -> stopped := true) })
  ;;

  let burst ~source ~snapshots ~resources ~findings : Source_event.t list =
    List.init snapshots ~f:(fun i ->
      Source_event.Diagnostics
        { source
        ; resource = sprintf "burst-%d.ml" (i % resources)
        ; revision = Some (i + 1)
        ; findings =
            List.init findings ~f:(fun j : Finding.t ->
              { severity = (if j % 3 = 0 then Error else Warning)
              ; message = sprintf "synthetic burst finding %d of snapshot %d" j i
              ; location = Some { line = j + 1; column = 1 }
              })
        })
  ;;
end
