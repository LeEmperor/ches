open! Core

(** Shared literal search semantics. [at] must be a UTF-8 boundary. *)
val matches
  : Text_buffer.t
  -> query:string
  -> whole_word:bool
  -> case_sensitive:bool
  -> at:int
  -> bool

val small_word_class : Text_buffer.t -> int -> [ `Identifier | `Punctuation ] option
