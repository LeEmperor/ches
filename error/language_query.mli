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
type kind = Hover | Declaration | Definition [@@deriving sexp_of, equal]
type request =
  { token : Ches_completion.Model.Token.t; cursor : int; kind : kind }
[@@deriving sexp_of, equal]
type result = Hover_result of hover option | Locations of target list | Failed of string
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
