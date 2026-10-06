(** What the host may do with a view. Role is workspace metadata only: it implies no
    capability, so a major view can be read-only and a minor one could accept input. *)

open! Core

module Role : sig
  type t =
    | Major (** A primary work surface, such as the editor. *)
    | Minor (** A supporting view, such as problems or a report. *)
  [@@deriving sexp_of, equal]
end

type t =
  { id : View_id.t
  ; title : string (** For capture notices, e.g. ["Problems"]. *)
  ; role : Role.t
  ; focusable : bool (** Can own keyboard input. *)
  ; accepts_paste : bool (** A paste started here is delivered rather than rejected. *)
  ; owns_cursor : bool (** Supplies the terminal cursor while focused. *)
  }
[@@deriving sexp_of]

(** Major, focusable, accepts paste, owns the cursor: the editor. *)
val primary : View_id.t -> title:string -> t

(** Minor, focusable, read-only: rejects paste and draws no terminal cursor. *)
val read_only : View_id.t -> title:string -> t

(** Minor and not focusable, such as status: it observes, never captures input. *)
val companion : View_id.t -> title:string -> t
