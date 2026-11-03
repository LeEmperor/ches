type t
val create : Ches_error.Language_query.signature_help -> t
val cycle : t -> int -> t
val rows : t -> Span.t list list
