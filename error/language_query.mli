open! Core

type encoding = Utf8 | Utf16 | Utf32 [@@deriving sexp_of, equal]
type position = { line : int; character : int } [@@deriving sexp_of, equal]
type range = { start : position; stop : position } [@@deriving sexp_of, equal]
type target =
  { path : string; range : range; selection : range; encoding : encoding }
[@@deriving sexp_of, equal]
type content_kind = Plaintext | Markdown [@@deriving sexp_of, equal]
type content = { kind : content_kind; value : string } [@@deriving sexp_of, equal]
type hover = { contents : content list; range : range option } [@@deriving sexp_of, equal]
(** Half-open UTF-8 byte offsets in the signature label. [-1, -1] means the
    server's label could not be located unambiguously; never highlight that slot. *)
type parameter = { label_start : int; label_stop : int; documentation : content list }
[@@deriving sexp_of, equal]
type signature =
  { label : string; documentation : content list; parameters : parameter list
  ; active_parameter : int option }
[@@deriving sexp_of, equal]
type signature_help =
  { signatures : signature list; active_signature : int; active_parameter : int option }
[@@deriving sexp_of, equal]
type instance = { hier_path : string; target : target option } [@@deriving sexp_of, equal]
type instance_list =
  { module_name : string; module_range : range; encoding : encoding
  ; active : string option; instances : instance list }
[@@deriving sexp_of, equal]
type instance_activated = { module_name : string; hier_path : string } [@@deriving sexp_of, equal]
type kind = Hover | Declaration | Definition | References | Instances
  | Activate_instance of instance_activated | Instantiation
  | Signature_help of { automatic : bool; character : string option; retrigger : bool }
  | Companion_files [@@deriving sexp_of, equal]
type request =
  { token : Ches_completion.Model.Token.t; cursor : int; kind : kind }
[@@deriving sexp_of, equal]
type result = Hover_result of hover option | Locations of target list
  | Instance_list of instance_list | Instance_activated of instance_activated
  | Signature_result of signature_help option | Companions of string list | Failed of string
[@@deriving sexp_of, equal]
type reply =
  { token : Ches_completion.Model.Token.t
  ; cursor : int
  ; kind : kind
  ; source : string
  ; result : result
  }
[@@deriving sexp_of, equal]

(** Exact byte offset, zero based. Rejects negative/out-of-range positions,
    malformed UTF-8, and positions splitting a code point or UTF-16 pair.
    Lines exclude CR in CRLF; the end of a line is valid. No Async dependency. *)
val offset : encoding -> text:string -> position -> int option

(** Automatic signature failures clear help silently; other queries report Failed. *)
val unavailable : kind -> string -> result
