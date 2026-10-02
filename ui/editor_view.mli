(** The editor as a Bonsai_term app.

    All UI state lives in one [Bonsai.state_machine_with_input] over
    {!Ches_screen.Ui_state}, so each terminal event is applied to the current state,
    never to the state of the last frame. The component only adapts events, runs the
    transition, draws {!Ches_screen.Frame}, and places the terminal cursor. *)

open! Core
open Bonsai_term

val app
  :  ?smear_enabled:bool
  -> Ches_app.Controller.t
  -> exit:(unit -> unit Effect.t)
  -> dimensions:Dimensions.t Bonsai.t
  -> local_ Bonsai.graph
  -> view:View.t Bonsai.t * handler:(Event.t -> unit Effect.t) Bonsai.t

(** Draws a frame. Each span is forced to its computed width, so a grapheme cluster
    that the terminal library measures differently cannot shift the layout. *)
val draw : Ches_screen.Frame.t -> View.t

(** Runs the editor in the terminal until it exits. SIGTERM and SIGHUP end the process
    with status 1, discarding unsaved changes, after restoring the terminal. *)
val run : Ches_app.Controller.t -> unit Async.Deferred.Or_error.t
