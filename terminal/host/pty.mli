(** Linux nonblocking PTY operations. Spawning and exec are entirely C-side. *)
type t
val spawn : cwd:string -> rows:int -> cols:int -> t
(** None means EAGAIN, Some "" means EOF (including Linux PTY EIO). *)
val read : t -> string option
val write : t -> string -> pos:int -> int
val resize : t -> rows:int -> cols:int -> unit
val poll_exit : t -> string option
val signal : t -> force:bool -> unit
val close : t -> unit
