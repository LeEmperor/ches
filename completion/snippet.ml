open! Core
open Ches_core
module B = Text_buffer

type range = { start : int; stop : int } [@@deriving sexp_of, equal, compare]
type field = { number : int; ranges : range list } [@@deriving sexp_of, equal, compare]
type occurrence = { number : int; range : range } [@@deriving sexp_of, equal]
type part = Literal of string | Stop of int | Variable of string * string option
[@@deriving sexp_of, equal]
type t =
  { expanded : string; occurrences : occurrence list
  ; parts : part list; defaults : part list Int.Map.t
  ; raw_choices : string list Int.Map.t; choices : string list Int.Map.t
  ; prefixes : string list; path : string option }
[@@deriving sexp_of, equal]

let max_input = 65_536
let max_output = 1_048_576
let max_ranges = 4096
let text t = t.expanded

let grouped occurrences =
  List.fold occurrences ~init:Int.Map.empty ~f:(fun map o ->
    if o.number = 0 then map else
      Map.add_multi map ~key:o.number ~data:o.range)
  |> Map.to_alist
  |> List.map ~f:(fun (number, ranges) -> { number; ranges = List.rev ranges })
;;

let fields t = grouped t.occurrences
let final_offset occurrences ~default =
  List.find_map occurrences ~f:(fun o ->
    if o.number = 0 then Some o.range.start else None)
  |> Option.value ~default
;;
let final_cursor t = final_offset t.occurrences ~default:(String.length t.expanded)

exception Invalid_snippet of string
let invalid message = raise (Invalid_snippet message)

let variable_names = [ "TM_FILENAME"; "TM_FILENAME_BASE"; "TM_DIRECTORY"; "TM_FILEPATH" ]

let variable_value name path =
  Option.map (Option.filter path ~f:(fun p -> not (String.is_empty p))) ~f:(fun path ->
    match name with
    | "TM_FILEPATH" -> path
    | "TM_DIRECTORY" -> Filename.dirname path
    | "TM_FILENAME" -> Filename.basename path
    | _ ->
      let filename = Filename.basename path in
      match String.rsplit2 filename ~on:'.' with
      | Some (base, _) -> base
      | None -> filename)
;;

let add_indent value prefix =
  let newlines = String.count value ~f:(Char.equal '\n') in
  if String.length value > max_output
     || (newlines > 0 && String.length prefix > (max_output - String.length value) / newlines)
  then invalid "indented snippet exceeds output limit";
  String.concat ~sep:("\n" ^ prefix) (String.split value ~on:'\n')
;;

let expand t ~path =
  try
    Option.iter path ~f:(fun path ->
      match B.validate path with Ok () -> () | Error _ -> invalid "invalid UTF-8 snippet path");
    let output = Buffer.create 128 in
    let occurrences = ref [] in
    let indent s = List.fold t.prefixes ~init:s ~f:add_indent in
    let append s =
      let s = indent s in
      if String.length s > max_output - Buffer.length output
      then invalid "snippet expansion exceeds 1048576 bytes";
      Buffer.add_string output s
    in
    let append_value = function
      | Literal s -> append s
      | Variable (name, default) ->
        append (Option.first_some (variable_value name path) default |> Option.value ~default:"")
      | Stop _ -> assert false
    in
    List.iter t.parts ~f:(function
      | Literal s -> append s
      | Variable (name, default) ->
        append (Option.first_some (variable_value name path) default |> Option.value ~default:"")
      | Stop number ->
        let start = Buffer.length output in
        if number <> 0 then List.iter (Option.value (Map.find t.defaults number) ~default:[]) ~f:append_value;
        occurrences := { number; range = { start; stop = Buffer.length output } } :: !occurrences);
    let choice_bytes = ref 0 in
    let choices = Map.map t.raw_choices ~f:(List.map ~f:(fun value ->
      let value = indent value in
      choice_bytes := !choice_bytes + String.length value;
      if !choice_bytes > max_output then invalid "snippet choices exceed output limit";
      value)) in
    let has_variable = List.exists ~f:(function Variable _ -> true | _ -> false) in
    let path = if has_variable t.parts || Map.exists t.defaults ~f:has_variable
      then path else None in
    Ok { t with expanded = Buffer.contents output; occurrences = List.rev !occurrences; choices; path }
  with Invalid_snippet message -> Or_error.error_string message
;;

let resolve = expand

let parse input =
  try
    if String.length input > max_input then invalid "snippet input exceeds 65536 bytes";
    (match B.validate input with
     | Ok () -> ()
     | Error e -> invalid (B.Invalid_text.to_string_hum e));
    let length = String.length input in
    let at = ref 0 in
    let count = ref 0 in
    let defaults = ref Int.Map.empty in
    let choices = ref Int.Map.empty in
    let parts = ref [] in
    let literal = Buffer.create 128 in
    let flush () =
      if Buffer.length literal > 0 then (
        parts := Literal (Buffer.contents literal) :: !parts;
        Buffer.clear literal)
    in
    let escaped target =
      incr at;
      if !at >= length then invalid "trailing snippet escape";
      let c = input.[!at] in
      if not (Char.equal c '\\' || Char.equal c '$' || Char.equal c '}')
      then invalid "unsupported snippet escape";
      Buffer.add_char target c;
      incr at
    in
    let number () =
      let start = !at in
      while !at < length && Char.is_digit input.[!at] do incr at done;
      if !at = start then invalid "expected numbered tabstop";
      if !at - start > 9 then invalid "tabstop number too large";
      Int.of_string (String.sub input ~pos:start ~len:(!at - start))
    in
    let final_seen = ref false in
    let default_literal () =
      incr at;
      let value = Buffer.create 32 in
      while !at < length && not (Char.equal input.[!at] '}') do
        match input.[!at] with
        | '\\' -> escaped value
        | '$' -> invalid "variable fallbacks must be literal"
        | c -> Buffer.add_char value c; incr at
      done;
      if !at >= length then invalid "unterminated default";
      incr at;
      Buffer.contents value
    in
    (* Called after '$' (and an optional '{'). This helper only accepts filename
       variables; its fallback parser never calls back into snippet parsing. *)
    let variable ~braced =
      let start = !at in
      while !at < length && (Char.is_alphanum input.[!at] || Char.equal input.[!at] '_') do incr at done;
      let name = String.sub input ~pos:start ~len:(!at - start) in
      if not (List.mem variable_names name ~equal:String.equal)
      then invalid ("unsupported snippet variable " ^ name);
      let default =
        if not braced then None
        else if !at >= length then invalid "unterminated variable"
        else match input.[!at] with
          | '}' -> incr at; None
          | ':' -> Some (default_literal ())
          | _ -> invalid "variable transformations are unsupported"
      in
      Variable (name, default)
    in
    let numbered_default () =
      incr at;
      let values = ref [] in
      let text = Buffer.create 32 in
      let flush () =
        if Buffer.length text > 0 then (
          values := Literal (Buffer.contents text) :: !values;
          Buffer.clear text)
      in
      while !at < length && not (Char.equal input.[!at] '}') do
        match input.[!at] with
        | '\\' -> escaped text
        | '$' ->
          flush ();
          incr at;
          let braced = !at < length && Char.equal input.[!at] '{' in
          if braced then incr at;
          if !at >= length || not (Char.is_alpha input.[!at] || Char.equal input.[!at] '_')
          then invalid "numbered defaults may contain only filename variables";
          values := variable ~braced :: !values
        | c -> Buffer.add_char text c; incr at
      done;
      if !at >= length then invalid "unterminated numbered default";
      incr at;
      flush ();
      List.rev !values
    in
    while !at < length do
      match input.[!at] with
      | '\\' -> escaped literal
      | '$' ->
        flush ();
        incr at;
        let braced = !at < length && Char.equal input.[!at] '{' in
        if braced then incr at;
        if !at < length && (Char.is_alpha input.[!at] || Char.equal input.[!at] '_') then (
          parts := variable ~braced :: !parts)
        else (
        let n = number () in
        let default =
          if not braced then None
          else if !at >= length then invalid "unterminated tabstop"
          else match input.[!at] with
            | '}' -> incr at; None
            | ':' ->
              if n = 0 then invalid "final cursor defaults are unsupported";
               Some (numbered_default ())
             | '|' ->
               if n = 0 then invalid "final cursor choices are unsupported";
               incr at;
               let values = ref [] in
               let value = Buffer.create 32 in
               let push () = values := Buffer.contents value :: !values; Buffer.clear value in
               while !at < length && not (Char.equal input.[!at] '|') do
                 match input.[!at] with
                 | ',' -> push (); incr at
                 | '\\' ->
                   incr at;
                   if !at >= length || not (List.mem [ ','; '|'; '\\' ] input.[!at] ~equal:Char.equal)
                   then invalid "unsupported choice escape";
                   Buffer.add_char value input.[!at]; incr at
                 | c -> Buffer.add_char value c; incr at
               done;
               if !at + 1 >= length || not (Char.equal input.[!at + 1] '}')
               then invalid "unterminated choice";
               at := !at + 2;
               push ();
               let values = List.rev !values in
               (match Map.find !choices n with
                | Some old when not (List.equal String.equal old values) -> invalid "conflicting linked choices"
                | _ -> choices := Map.set !choices ~key:n ~data:values);
               let first = List.hd_exn values in
               Some (if String.is_empty first then [] else [Literal first])
             | _ -> invalid "transformations are unsupported"
        in
        incr count;
        if !count > max_ranges then invalid "too many snippet ranges";
        if n = 0 then (
          if !final_seen then invalid "multiple final cursor markers";
          final_seen := true);
        Option.iter default ~f:(fun value ->
          match Map.find !defaults n with
          | Some old when not (List.equal equal_part old value) -> invalid "conflicting linked defaults"
          | _ -> defaults := Map.set !defaults ~key:n ~data:value);
         parts := Stop n :: !parts)
      | c -> Buffer.add_char literal c; incr at
    done;
    flush ();
    expand { expanded = ""; occurrences = []; parts = List.rev !parts
           ; defaults = !defaults; raw_choices = !choices; choices = !choices; prefixes = []; path = None } ~path:None
  with Invalid_snippet message -> Or_error.error_string message
;;

let indent t ~prefix =
  if String.length prefix >= max_input then Or_error.error_string "indentation exceeds input limit"
  else match B.validate prefix with
  | Error _ -> Or_error.error_string "invalid UTF-8 indentation"
  | Ok () ->
    if String.is_empty prefix then Ok t
    else expand { t with prefixes = t.prefixes @ [prefix] } ~path:t.path
;;

module Session = struct
  type template = t
  type t =
    { base : int
    ; length : int
    ; occurrences : occurrence list
    ; active_number : int option
    ; active_index : int
    ; selected : range option
    ; caret : int
    ; revision : int
    ; snapshot : B.t
    ; choices : string list Int.Map.t
    ; choice_indices : int Int.Map.t
    }
  [@@deriving sexp_of]
  type direction = Next | Previous [@@deriving sexp_of, equal]
  type change = { next : t; edits : Text_edit.t list }

  let fields t = grouped t.occurrences
  let active t =
    Option.bind t.active_number ~f:(fun number ->
      List.find (fields t) ~f:(fun field -> field.number = number))
  ;;
  let selection t = t.selected
  let choices t = Option.bind t.active_number ~f:(Map.find t.choices)
  let cursor t = t.caret
  let finished t = Option.is_none t.active_number
  let matches t ~revision ~text =
    revision = t.revision && (phys_equal text t.snapshot || B.equal text t.snapshot)
  ;;
  let select t field =
    let range = List.hd_exn field.ranges in
    { t with active_number = Some field.number; active_index = 0
    ; selected = Some range; caret = range.stop }
  ;;
  let finish t =
    { t with active_number = None; selected = None
    ; caret = final_offset t.occurrences ~default:(t.base + t.length) }
  ;;
  let start template ~base ~revision ~text =
    let length = String.length template.expanded in
    if base < 0 || base > B.length text || length > B.length text - base
       || not (B.is_boundary text base) || not (B.is_boundary text (base + length))
    then Or_error.error_string "snippet base is not a valid document range"
    else if not (String.equal template.expanded (B.slice text ~pos:base ~len:length))
    then Or_error.error_string "snippet expansion does not match installed text"
    else
      let occurrences = List.map template.occurrences ~f:(fun o ->
        { o with range = { start = base + o.range.start; stop = base + o.range.stop } })
      in
      let t = { base; length; occurrences; active_number = None; active_index = 0; selected = None
              ; caret = base; revision; snapshot = text; choices = template.choices
              ; choice_indices = Int.Map.empty } in
      Ok (match List.hd (fields t) with None -> finish t | Some field -> select t field)
  ;;
  let navigate t direction =
    match t.active_number with
    | None -> t
    | Some number ->
      let fields = fields t in
      match direction with
      | Next ->
        (match List.find fields ~f:(fun f -> f.number > number) with
         | None -> finish t
         | Some field -> select t field)
      | Previous ->
        let field = List.filter fields ~f:(fun f -> f.number < number) |> List.last in
        select t (Option.value field ~default:(List.hd_exn fields))
  ;;
  let active_range t = Option.bind (active t) ~f:(fun field -> List.nth field.ranges t.active_index)
  let set_cursor t caret =
    let contains range = caret >= range.start && caret <= range.stop in
    let index =
      match active_range t with
      | Some range when contains range -> Some t.active_index
      | _ -> Option.bind (active t) ~f:(fun field ->
          List.findi field.ranges ~f:(fun _ range -> contains range) |> Option.map ~f:fst)
    in
    match index with
    | Some active_index when B.is_boundary t.snapshot caret ->
      Ok { t with caret; selected = None; active_index }
    | _ -> Or_error.error_string "caret is outside the active field or not a UTF-8 boundary"
  ;;

  let replace t ~revision ~text ~start ~stop ~replacement =
    let open Or_error.Let_syntax in
    if not (matches t ~revision ~text) then Or_error.error_string "stale snippet session"
    else
      match active_range t with
      | None -> Or_error.error_string "snippet session is finished"
      | Some range ->
        if start < range.start || stop < start || stop > range.stop
           || not (B.is_boundary text start) || not (B.is_boundary text stop)
        then Or_error.error_string "edit is outside the active field or not a UTF-8 boundary"
        else if String.length replacement > max_output then
          Or_error.error_string "snippet replacement exceeds output limit"
        else
          let%bind () = Result.map_error (B.validate replacement)
            ~f:(fun e -> Error.of_string (B.Invalid_text.to_string_hum e)) in
          let value = B.slice text ~pos:range.start ~len:(start - range.start)
            ^ replacement ^ B.slice text ~pos:stop ~len:(range.stop - stop) in
          let number = Option.value_exn t.active_number in
          let mirrors = List.count t.occurrences ~f:(fun o -> o.number = number) in
          let delta = String.length value - (range.stop - range.start) in
          let length = t.length + mirrors * delta in
          if length > max_output then Or_error.error_string "snippet edit exceeds output limit"
          else
            let output = Buffer.create length in
            let previous = ref t.base in
            let shift = ref 0 in
            let occurrences = List.map t.occurrences ~f:(fun o ->
              let start = o.range.start + !shift in
              if o.number = number then (
                Buffer.add_string output (B.slice text ~pos:!previous
                  ~len:(o.range.start - !previous));
                Buffer.add_string output value;
                previous := o.range.stop;
                shift := !shift + delta;
                { o with range = { start; stop = start + String.length value } })
              else { o with range = { start; stop = o.range.stop + !shift } })
            in
            Buffer.add_string output (B.slice text ~pos:!previous
              ~len:(t.base + t.length - !previous));
            let edits = [ { Text_edit.start = t.base; stop = t.base + t.length
                          ; text = Buffer.contents output } ] in
            let%map snapshot = Text_edit.apply text [ edits ] in
            let tracked = List.filter occurrences ~f:(fun o -> o.number = number)
              |> Fn.flip List.nth_exn t.active_index in
            let caret = tracked.range.start + start - range.start + String.length replacement in
            { edits; next = { t with length; occurrences; caret; selected = None; snapshot
                                   ; choice_indices = Map.remove t.choice_indices number } }
  ;;
  let insert t ~revision ~text replacement =
    let range = Option.value t.selected ~default:{ start = t.caret; stop = t.caret } in
    replace t ~revision ~text ~start:range.start ~stop:range.stop ~replacement
  ;;
  let cycle_choice t direction ~revision ~text =
    let open Or_error.Let_syntax in
    if not (matches t ~revision ~text) then Or_error.error_string "stale snippet session"
    else match choices t, active_range t with
    | Some values, Some range ->
      let current = B.slice text ~pos:range.start ~len:(range.stop - range.start) in
      let number = Option.value_exn t.active_number in
      let index = Option.first_some (Map.find t.choice_indices number)
        (List.findi values ~f:(fun _ value -> String.equal value current) |> Option.map ~f:fst) in
      let count = List.length values in
      let index = match direction, index with
        | Next, None -> 0 | Previous, None -> count - 1
        | Next, Some i -> (i + 1) mod count
        | Previous, Some i -> (i + count - 1) mod count in
      let%map change = replace t ~revision ~text ~start:range.start ~stop:range.stop
        ~replacement:(List.nth_exn values index) in
      let selected = active_range change.next in
      { change with next = { change.next with selected
        ; choice_indices = Map.set change.next.choice_indices ~key:number ~data:index } }
    | _ -> Or_error.error_string "active snippet field has no choices"
  ;;
  let edits change = change.edits
  let cursor_after change = change.next.caret
  let applied change ~revision = { change.next with revision }
end
