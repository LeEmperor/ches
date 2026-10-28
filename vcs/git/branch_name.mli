(** New branch names (phase 6): the check the name prompt runs on every edit, so the
    user sees why a name is refused before anything runs. Pure: the rules of [git
    check-ref-format --branch] (git-check-ref-format(1)) for the name [refs/heads/
    <name>], which git's own [switch --create] applies again when the branch is
    made. *)

open! Core

(** Why [name] cannot be a new branch, or [None]. The first that applies:
    - empty: ["Enter a branch name"];
    - not valid, as ["Not a valid branch name: <reason>"], with the first reason
      that applies: ["it starts with '-'"]; ["it is HEAD"]; ["it is '@'"]; ["it
      contains a space"]; ["it contains a control character"] (bytes below 0x20 and
      0x7f); ["it contains '<c>'"] for each of [~ ^ : ? * \[ \\]; ["it contains
      '..'"]; ["it contains '@{'"]; ["it starts or ends with '/'"]; ["it contains
      '//'"]; ["it ends with '.'"]; ["a part starts with '.'"] (a part is the text
      between slashes); ["a part ends with '.lock'"];
    - in [existing] (local branch names): ["A branch named <name> already exists"].
    Other bytes, non-ASCII included, are allowed, as git allows them. Stricter than
    git in two places, deliberately: ["@"] (git 2.43 accepts it, but it reads as
    HEAD in revisions) and ["@{-N}"] (which [--branch] expands to an earlier
    branch's name). *)
val refusal : existing:string list -> string -> string option
