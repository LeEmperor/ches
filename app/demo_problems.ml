open! Core
open Ches_core
module Feedback = Ches_error.Error

let install controller =
  let editor = Controller.editor controller in
  match Editor.path editor with
  | None -> controller
  | Some resource ->
    let last_line = Text_buffer.line_count (Editor.text editor) - 1 in
    List.fold (List.range 0 8) ~init:controller ~f:(fun controller i ->
      (* Each fixture uses its own demo namespace, independent of real file outcomes.
         Collection/per-item diagnostic identities are intentionally phase 9 work. *)
      let identity : Feedback.Identity.t =
        { source = sprintf "demo/%02d" (i + 1); kind = Save; resource } in
      let line = 1 + (i * last_line / 7) in
      let severity = match i % 3 with 0 -> Feedback.Severity.Info | 1 -> Warning | _ -> Error in
      let text = sprintf "DEMO %d/8: jump to line %d, column 1. Synthetic finding, not a real diagnostic."
        (i + 1) line in
      let text = if i = 7 then text ^ " " ^ String.concat ~sep:" "
        (List.init 8 ~f:(fun _ ->
          "Use j/k or Ctrl-d/u to scroll these demo details; e closes details and Enter jumps."))
        else text in
      controller
      |> fun c -> Controller.update_feedback c
        (Report (identity, severity, text, Some { line; column = 1 }))
      |> fun c -> Controller.update_feedback c (Acknowledge_identity identity))
;;
