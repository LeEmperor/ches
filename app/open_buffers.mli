open! Core

(** Ordered, transient file-buffer display data. Session owns identity, order and
    activation; this projection owns no state and knows nothing of screen layout.
    Labels are shortest disambiguating path suffixes, with unsafe bytes escaped. *)
type t =
  { id : Buffer_id.t
  ; label : string
  ; active : bool
  ; modified : bool
  ; missing : bool
  }
[@@deriving sexp_of]

val of_session : Session.t -> t list
