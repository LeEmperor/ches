open! Core
open! Async
type t
val create : unit -> t
val follow : t -> Ches_screen.Ui_state.word_index_request option -> unit
val next : t -> (Ches_screen.Ui_state.word_index_request * Ches_completion.Model.Buffer_words.t) option Deferred.t
val stop : t -> unit
