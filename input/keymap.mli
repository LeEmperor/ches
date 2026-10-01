(** Modal key bindings: a state machine from {!Input.t} to editor commands.

    The keymap owns only the pending key sequence (e.g. a Space leader waiting for its
    continuation). The editor's mode is passed in on every call, so the frontend
    reads it from [Editor.mode] after dispatching the previous commands.

    {2 Bindings}

    {v
      Mode    Keys                   Command
      Normal  h / j / k / l          Move Left / Down / Up / Right
      Normal  i                      Enter_insert
      Normal  x                      Delete_char
      Normal  u                      Undo
      Normal  Ctrl-r                 Redo
      Normal  Space w                Save
      Normal  Space q                Quit
      Normal  Space Q                Force_quit
      Normal  Escape                 Cancel a pending sequence
      Insert  characters, Space      Insert_text (literal)
      Insert  Enter                  Insert_text "\n"
      Insert  Tab                    Insert_soft_tab or Insert_text "\t" ({!Config.tab})
      Insert  Backspace              Delete_soft_tab_backward or Delete_backward
      Insert  Delete                 Delete_forward
      Insert  Escape                 Exit_insert
      Insert  j k                    Exit_insert ({!Config.insert_escape})
    v}

    The Insert-mode escape sequence (default [j k]) has no timeout and never hides
    typed text: [j] is inserted as soon as it is typed, and an immediately following
    [k] produces [Delete_backward; Exit_insert], removing the [j] before leaving
    Insert. Typing [j] then [k] literally therefore needs another route, such as a
    paste. Any other input in between, including a paste, ends the sequence.

    Other keys are ignored. In Normal mode, a key that does not continue a pending
    sequence cancels it without producing commands, and sets {!notice}. A pending
    leader has no timeout.

    Pasted text becomes one literal [Insert_text] in Insert mode. In Normal mode it
    is ignored (cancelling any pending sequence) with a {!notice}; it is never
    interpreted as Normal-mode keys. *)

(* [open! Core] would shadow our [Command] with Core's command-line [Command]. *)
module Editor_command := Ches_core.Command

open! Core
module Command := Editor_command

module Input : sig
  (** {2 Adapter contract for paste}

      A frontend delivers a paste as a single [Paste] holding the exact pasted text,
      not as the key presses that make it up. With a terminal that brackets pastes
      (Bonsai_term reports [Paste `Start], key presses, [Paste `End]), the adapter
      collects the bracketed keys into a string, e.g. with {!Key.text}, and sends one
      [Paste] at the end. The text is not normalized: CR bytes and other invalid text
      are passed through and rejected by the editor, which reports an error. *)
  type t =
    | Key of Key.t
    | Paste of string
  [@@deriving sexp_of]
end

module Config : sig
  type tab =
    | Literal_tab (** Tab inserts a TAB character; Backspace deletes one code point. *)
    | Spaces of int
    (** Soft tabs of this width, at least 1: Tab inserts spaces to the next multiple
        of the width, and Backspace deletes spaces back to the previous one. *)
  [@@deriving sexp_of]

  type t =
    { tab : tab
    ; insert_escape : (char * char) option
    (** Two printable ASCII characters that leave Insert mode when typed in a row,
        or [None] for Escape only. *)
    }
  [@@deriving sexp_of]

  (** [Spaces 2] and [Some ('j', 'k')]. *)
  val default : t
end

type t [@@deriving sexp_of]

(** A keymap with no pending sequence. Raises if [config.tab] is [Spaces n] with
    [n < 1]. *)
val create : Config.t -> t

(** [feed t ~mode input] interprets [input] in [mode] and returns the commands to
    dispatch, in order. *)
val feed : t -> mode:Ches_core.Mode.t -> Input.t -> t * Command.t list

(** The keys of an incomplete sequence, for the status line, e.g. ["Space"]. *)
val pending : t -> string option

(** Feedback about the most recent {!feed}, e.g. ["Space x is not bound"]. Cleared
    by the next {!feed}. Independent of the editor's own message. *)
val notice : t -> string option
