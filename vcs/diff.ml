open! Core

module Line = struct
  module Kind = struct
    type t =
      | Context
      | Added
      | Removed
      | No_newline
    [@@deriving sexp, equal]
  end

  type t =
    { kind : Kind.t
    ; prefix : string
    ; text : string
    ; old_line : int option
    ; new_line : int option
    }
  [@@deriving sexp, equal]
end

module Hunk = struct
  type t =
    { header : string
    ; old_start : int
    ; old_count : int
    ; new_start : int
    ; new_count : int
    ; section : string
    ; lines : Line.t list
    }
  [@@deriving sexp, equal]
end

module File = struct
  module Change = struct
    type t =
      | Added
      | Deleted
      | Modified
      | Renamed of { similarity : int option }
      | Copied of { similarity : int option }
      | Type_changed
      | Unmerged
    [@@deriving sexp, equal]
  end

  module Truncated = struct
    type t =
      { omitted_hunks : int
      ; omitted_lines : int
      ; cut : bool
      }
    [@@deriving sexp, equal]
  end

  type t =
    { old_path : string option
    ; new_path : string option
    ; change : Change.t
    ; old_mode : string option
    ; new_mode : string option
    ; header : string list
    ; hunks : Hunk.t list
    ; binary : bool
    ; submodule : bool
    ; combined : bool
    ; truncated : Truncated.t option
    }
  [@@deriving sexp, equal]

  let path t = Option.first_some t.new_path t.old_path |> Option.value ~default:""

  let mode_only t =
    Change.equal t.change Modified
    && List.is_empty t.hunks
    && (not t.binary)
    &&
    match t.old_mode, t.new_mode with
    | Some old_mode, Some new_mode -> not (String.equal old_mode new_mode)
    | _ -> false
  ;;

  let rename_only t =
    (match t.change with
     | Renamed _ | Copied _ -> true
     | Added | Deleted | Modified | Type_changed | Unmerged -> false)
    && List.is_empty t.hunks
    && not t.binary
  ;;

  let line_actions t =
    not
      (t.binary
       || t.submodule
       || t.combined
       || Change.equal t.change Unmerged
       || mode_only t
       || rename_only t)
  ;;
end

module Limits = struct
  type t =
    { file_lines : int
    ; file_bytes : int
    }
  [@@deriving sexp, equal]

  let default = { file_lines = 2000; file_bytes = 256 * 1024 }
end

type t =
  { preamble : string list
  ; files : File.t list
  ; cut : bool
  }
[@@deriving sexp, equal]

let empty = { preamble = []; files = []; cut = false }
