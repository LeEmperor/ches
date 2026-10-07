(** The editor as a Bonsai_term app.

    All UI state lives in one [Bonsai.state_machine_with_input] over
    {!Ches_screen.Ui_state}, so each terminal event is applied to the current state,
    never to the state of the last frame. The component only adapts events, runs the
    transition, draws {!Ches_screen.Frame}, and places the terminal cursor. *)

open! Core
open Bonsai_term

module File_picker_host : sig
  (** Explicit assembly/test boundary. The caller opens [initial_ui] through the
      Async runtime and supplies a real/test consumer. No default opener, binding,
      or command entry is installed. The frontend yields and chains bounded work
      independently of redraws, and delivers intents only after capture release.
      Deactivation closes the filtering session and cancels discovery; the owner
      may await [Runtime.finished] at teardown. [initial_ui] must own the controller/source configuration supplied
      to [app], rather than an unrelated document. *)
  type t =
    { initial_ui : Ches_screen.Ui_state.t
    ; runtime : Ches_file_picker_host.Runtime.t
    ; consume : Ches_tile.View_id.t Ches_file_picker.Model.Request.t -> unit
    }
end

module Content_picker_host : sig
  (** Test assembly only; no live activation or invented open-at-location adapter. *)
  type t =
    { initial_ui : Ches_screen.Ui_state.t
    ; runtime : Ches_content_picker_host.Runtime.t
    ; consume : Ches_tile.View_id.t Ches_content_picker.Model.intent -> unit
    }
end

(** [font] gives the font styles of each part of the screen; the default is
    {!Theme.Font.default}. Current-document line work is always scheduled through
    yielded bounded turns; [file_picker] is only the optional file-consumer boundary. *)
val app
  :  ?smear_enabled:bool
  -> ?report:Ches_screen.Report_tile.Item.t list
       (** Installs a static report view (see {!Ches_screen.Ui_state.create}). *)
  -> ?source:Ches_source.Source.t
       (** A running diagnostic source: its events become [Source] inputs, and
           {!Ches_screen.Ui_state.take_source_requests} is sent to it after each
           transition. *)
   -> ?font:(Ches_screen.Style.t -> Theme.Font.t list)
    -> ?file_picker:File_picker_host.t
    -> ?content_picker:Content_picker_host.t
  -> Ches_app.Controller.t
  -> exit:(unit -> unit Effect.t)
  -> dimensions:Dimensions.t Bonsai.t
  -> local_ Bonsai.graph
  -> view:View.t Bonsai.t * handler:(Event.t -> unit Effect.t) Bonsai.t

(** Draws a frame. Each span is forced to its computed width, so a grapheme cluster
    that the terminal library measures differently cannot shift the layout. *)
val draw : ?font:(Ches_screen.Style.t -> Theme.Font.t list) -> Ches_screen.Frame.t -> View.t

(** Runs the editor in the terminal until it exits, then stops [source]. SIGTERM and
    SIGHUP end the process with status 1, discarding unsaved changes, after restoring the
    terminal. *)
val run
  :  ?font:(Ches_screen.Style.t -> Theme.Font.t list)
  -> ?report:Ches_screen.Report_tile.Item.t list
  -> ?source:Ches_source.Source.t
  -> Ches_app.Controller.t
  -> unit Async.Deferred.Or_error.t
