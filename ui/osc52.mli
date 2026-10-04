(** OSC 52, the escape sequence asking the terminal to set the system clipboard. It
    reaches the clipboard of the machine running the terminal, so it also works over
    SSH. Terminals that do not support it, or are configured to refuse it, ignore it;
    tmux passes it on with [set-clipboard on]. *)

open! Core

(** The sequence setting the clipboard selection to [text]. *)
val set_clipboard : string -> string
