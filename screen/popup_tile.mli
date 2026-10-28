(** The popup float: a registered view's popup question
    ({!View_registry.Ask.t.Popup}, a {!Ches_vcs.Popup.t}, Magit's transient), opened
    on the single float slot over that view, which is neither left nor changed
    meanwhile. Read-only: keys are the popup's, per {!Ches_vcs.Popup.press}. [-] then
    a switch's key toggles that switch (enabling one disables its group's others); an
    action's key chooses it, which closes the float and performs the view's action for
    it with the enabled switches. Escape clears a pending [-], else declines; [q],
    Tab and Ctrl-c decline ({!Ui_state} routes the last two). [?] opens the help float
    over the popup, listing {!Ches_vcs.Popup.help}; closing help returns to the popup
    as it was. An unbound key shows a hint in the footer. Switches start disabled at
    every opening (nothing is remembered). *)

open! Core

val id : Ches_tile.View_id.t

(** {!Ches_tile.Spec.read_only}, title ["Popup"] (for paste notices). *)
val spec : Ches_tile.Spec.t

type t [@@deriving sexp_of]

(** No switch enabled, no dash pending. *)
val create : origin:Ches_tile.View_id.t -> unit Ches_vcs.Popup.t -> t

(** The view that asked, and that focus returns to. *)
val origin : t -> Ches_tile.View_id.t

(** The popup's title, also the float's. *)
val title : t -> string

val popup : t -> unit Ches_vcs.Popup.t
val state : t -> Ches_vcs.Popup.State.t

(** Outer size that shows every entry, the actions on one row and the switches one
    per row, when the screen allows (32 to 76 columns), and tall enough for the rows
    the entries take on a screen [screen] columns wide (narrower columns take more
    rows). *)
val preferred_size : t -> screen:int -> Floating.Size.t

(** The smallest outer size: a frame and two rows, as the confirmation's (20 by 4).
    Entries that do not fit are cut; [?] help lists them all. *)
val minimum : Floating.Size.t

type action =
  | Press of char (** A printable ASCII key other than space, [q] and [?]. *)
  | Escape
  | Help (** [?] *)
  | Close (** [q] *)
[@@deriving sexp_of, equal]

(** Single printable keys as above; everything else is unbound (the host's hint).
    Escape is given to the host as the content's back action. *)
val interpret : Ches_input.Key.t list -> action Ches_tile.Content_key.t

val hint : string

(** {!Ches_vcs.Popup.press}: [`Updated] after a dash or a toggle; [`Choose (key,
    enabled)] for an action key (the float then closes and answers
    {!View_registry.Answer.t.Choose}); [`Unbound] with the dash cleared and the
    footer hint ["<key> is unbound; ? lists keys"] (["-x"]
    after a dash). *)
val press
  :  t
  -> char
  -> [ `Updated of t | `Choose of char * string list | `Unbound of t * string ]

(** {!Ches_vcs.Popup.escape}: a pending dash is cleared, else [`Close]. *)
val escape : t -> [ `Close | `Updated of t ]

(** {!Ches_vcs.Popup.help}, for the help float. *)
val help : t -> (string * string) list

(** Shell content for a [width] by [rows] content viewport. The title is the
    popup's. The body: a ["Switches"] row, then one entry per switch,
    ["-n  Disable hooks (--no-verify)"], after a two-cell marker that is ["* "] when
    the switch is enabled (also drawn in {!Style.Pending}) and blank otherwise; then
    an ["Actions"] row and one entry per action, ["  c  Commit"]. Each group is laid
    out in as many columns as [width] allows (three cells apart, filled column by
    column); a group without entries is left out, and rows past [rows] are cut. The
    footer: a notice (an unbound key's hint), else a pending prefix ([pending], the
    host's, else ["-"] while a dash is pending), else, with [hotkey_hints], ["-
    switch  ? help  q close"]. *)
val render
  :  ?hotkey_hints:bool
  -> ?notice:string
  -> ?pending:string
  -> t
  -> width:int
  -> rows:int
  -> Tile_shell.Content.t
