open! Core

type encoding = Utf8 | Utf16 | Utf32 [@@deriving sexp_of, equal]
type position = { line : int; character : int } [@@deriving sexp_of, equal]
type range = { start : position; stop : position } [@@deriving sexp_of, equal]
type target = { path : string; range : range; selection : range; encoding : encoding }
[@@deriving sexp_of, equal]
type content_kind = Plaintext | Markdown [@@deriving sexp_of, equal]
type content = { kind : content_kind; value : string } [@@deriving sexp_of, equal]
type hover = { contents : content list; range : range option } [@@deriving sexp_of, equal]
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
type request = { token : Ches_completion.Model.Token.t; cursor : int; kind : kind }
[@@deriving sexp_of, equal]
type result = Hover_result of hover option | Locations of target list
  | Instance_list of instance_list | Instance_activated of instance_activated
  | Signature_result of signature_help option | Companions of string list | Failed of string
[@@deriving sexp_of, equal]
type reply =
  { token : Ches_completion.Model.Token.t; cursor : int; kind : kind
  ; source : string; result : result }
[@@deriving sexp_of, equal]

let unavailable kind message = match kind with
  | Signature_help { automatic = true; _ } -> Signature_result None
  | _ -> Failed message

let offset encoding ~text (p : position) =
  let length = String.length text in
  let rec walk byte line character =
    if line = p.line && character = p.character then Some byte
    else if byte = length || line > p.line then None
    else if Char.equal text.[byte] '\r' then
      let next = if byte + 1 < length && Char.equal text.[byte + 1] '\n'
        then byte + 2 else byte + 1 in
      walk next (line + 1) 0
    else if Char.equal text.[byte] '\n' then walk (byte + 1) (line + 1) 0
    else
      let d = Stdlib.String.get_utf_8_uchar text byte in
      let bytes = Stdlib.Uchar.utf_decode_length d in
      let units = match encoding with
        | Utf8 -> bytes | Utf32 -> 1
        | Utf16 -> if Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar d) >= 0x10000 then 2 else 1 in
      walk (byte + bytes) line (character + units)
  in
  if p.line < 0 || p.character < 0 || not (Stdlib.String.is_valid_utf_8 text)
  then None else walk 0 0 0
