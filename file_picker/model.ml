open! Core

module Candidate = struct
  module Id = struct
    type t = string [@@deriving sexp_of, equal, compare]

    let to_string t = t
  end

  type t =
    { root : string
    ; path : string
    ; relative_path : string
    ; display_path : string
    }
  [@@deriving sexp_of, fields ~getters]

  let id t = t.path

  let display_path_of_bytes ?(on_scalar = fun _ _ _ -> ()) s =
    let buffer = Buffer.create (String.length s) in
    let escape pos length =
      for i = pos to pos + length - 1 do
        Buffer.add_string buffer (sprintf "\\x%02X" (Char.to_int s.[i]))
      done
    in
    let rec loop pos =
      if pos < String.length s
      then (
        let decoded = Stdlib.String.get_utf_8_uchar s pos in
        let length = Stdlib.Uchar.utf_decode_length decoded in
        let scalar = Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar decoded) in
        let start = Buffer.length buffer in
        if not (Stdlib.Uchar.utf_decode_is_valid decoded)
           || scalar <= 0x1F
           || (scalar >= 0x7F && scalar <= 0x9F)
           || scalar = 0x2028
           || scalar = 0x2029
        then escape pos length
        else if scalar = 0x5C
        then Buffer.add_string buffer "\\\\"
        else Buffer.add_substring buffer s ~pos ~len:length;
        on_scalar pos start (Buffer.length buffer - start);
        loop (pos + length))
    in
    loop 0;
    Buffer.contents buffer
  ;;

  let display_positions t ~raw_positions =
    if String.equal t.relative_path t.display_path
    then List.dedup_and_sort raw_positions ~compare:Int.compare
    else (
      let wanted = Int.Set.of_list raw_positions in
      let positions = ref [] in
      let (_ : string) =
        display_path_of_bytes t.relative_path ~on_scalar:(fun raw start length ->
          if Set.mem wanted raw
          then (
            let decoded = Stdlib.String.get_utf_8_uchar t.relative_path raw in
            let raw_length = Stdlib.Uchar.utf_decode_length decoded in
            (* Escapes consist of ASCII characters; mark the entire representation.
               Unescaped UTF-8 contributes only its code-point start. *)
            if length <> raw_length || not (Stdlib.Uchar.utf_decode_is_valid decoded)
            then
              for offset = start to start + length - 1 do
                positions := offset :: !positions
              done
            else positions := start :: !positions))
      in
      List.dedup_and_sort !positions ~compare:Int.compare)
  ;;

  let display_text s = display_path_of_bytes s

  let create ~root ~relative_path =
    if String.is_empty root || not (Char.equal root.[0] '/')
    then Or_error.error_string "File picker root must be absolute"
    else if String.mem root '\000' || String.mem relative_path '\000'
    then Or_error.error_string "File picker paths cannot contain NUL"
    else if
      List.exists (String.split relative_path ~on:'/') ~f:(fun component ->
        String.is_empty component
        || String.equal component "."
        || String.equal component "..")
    then Or_error.error_string "File picker candidate must be a normalized relative path"
    else (
      let root = String.rstrip root ~drop:(Char.equal '/') in
      let root = if String.is_empty root then "/" else root in
      let separator = if String.equal root "/" then "" else "/" in
      Ok
        { root
        ; path = root ^ separator ^ relative_path
        ; relative_path
        ; display_path = display_path_of_bytes relative_path
        })
  ;;
end

module Run_id = struct
  type t = int [@@deriving sexp_of, equal]

  let of_int t = t
end

module Discovery = struct
  type request =
    { run_id : Run_id.t
    ; root : string
    }
   [@@deriving sexp_of, equal]

  type status =
    | Loading
    | Partial
    | Complete of { truncated : bool }
    | Failed of string
    | Cancelled
  [@@deriving sexp_of, equal]

  type t =
    { request : request
    ; candidates : Candidate.t list
    ; status : status
    }
  [@@deriving sexp_of]
end

module Query_result = struct
  type t =
    { candidate : Candidate.t
    ; score : int
    ; positions : int list
    }
  [@@deriving sexp_of]
end

module Request = struct
  type 'token t =
    { token : 'token
    ; path : string
    }
  [@@deriving sexp_of]
end

type 'token t =
  { token : 'token
  ; discovery : Discovery.t
  ; query : string
  ; results : Query_result.t list
  ; selected : Candidate.Id.t option
  }
[@@deriving fields ~getters]

let create ~token ~discovery =
  { token; discovery; query = ""; results = []; selected = None }
;;

let with_discovery t discovery = { t with discovery }

let find results id =
  List.find results ~f:(fun (result : Query_result.t) ->
    Candidate.Id.equal id (Candidate.id result.candidate))
;;

let with_results t ~query results =
  let selected =
    Ches_palette.Selection.preserve t.selected results
      ~id:(fun (result : Query_result.t) -> Candidate.id result.candidate)
      ~equal:Candidate.Id.equal
  in
  { t with query; results; selected }
;;

let select t id =
  if Option.is_some (find t.results id) then { t with selected = Some id } else t
;;

let accept t =
  Option.bind t.selected ~f:(fun id ->
    Option.map (find t.results id) ~f:(fun result ->
      { Request.token = t.token; path = Candidate.path result.candidate }))
;;
