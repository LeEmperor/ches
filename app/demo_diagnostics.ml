open! Core
open Ches_core
module Feedback = Ches_error.Error
module Source_event = Ches_error.Source_event

let install controller =
  let editor = Controller.editor controller in
  match Editor.path editor with
  | None -> controller
  | Some resource ->
    let revision = Editor.revision editor in
    let text = Editor.text editor in
    (* The empty line after a final newline is not worth flagging. *)
    let lines =
      let count = Text_buffer.line_count text in
      if count > 1 && String.is_empty (Text_buffer.line_text text (count - 1))
      then count - 1
      else count
    in
    let at line severity message : Feedback.Diagnostics.Finding.t =
      { severity
      ; message = "DEMO: " ^ message
      ; location = Some { line = Int.clamp_exn line ~min:1 ~max:lines; column = 1 }
      }
    in
    let root = Filename.dirname resource in
    let events : Source_event.t list =
      [ Diagnostics
          { source = "demo-check"
          ; resource
          ; revision = Some revision
          ; findings =
              [ at (lines / 2) Warning "synthetic unused value (versioned source)"
              ; at 1 Error "synthetic type error (versioned source)"
              ]
          }
      ; Diagnostics
          { source = "demo-lint"
          ; resource
          ; revision = None
          ; findings = [ at 2 Info "synthetic style hint (unversioned source)" ]
          }
      ; Diagnostics
          { source = "demo-check"
          ; resource = Filename.concat root "demo-other.ml"
          ; revision = Some 1
          ; findings = [ at 4 Error "synthetic finding in another file (never dims)" ]
          }
      ; Diagnostics
          { source = "demo-stopped"
          ; resource
          ; revision = Some revision
          ; findings = [ at lines Warning "synthetic finding from a stopped source" ]
          }
      ; Stopped
          { source = "demo-stopped"; root; reason = "DEMO: synthetic stop" }
      ]
    in
    List.fold events ~init:controller ~f:(fun controller event ->
      Controller.update_feedback
        controller
        (Source_event.to_update event ~current_revision:revision))
    |> fun controller ->
    Controller.update_feedback
      controller
      (Acknowledge_identity { source = "demo-stopped"; kind = Checker; resource = root })
;;
