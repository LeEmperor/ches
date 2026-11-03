open! Core
open Ches_core
module B = Text_buffer

type range = { start : int; stop : int } [@@deriving sexp_of, equal, compare]
type field = { number : int; ranges : range list } [@@deriving sexp_of, equal, compare]
type occurrence = { number : int; range : range } [@@deriving sexp_of, equal]
type t = { expanded : string; occurrences : occurrence list }
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

type part = Literal of string | Stop of int

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
      if !at = start then invalid "variables and non-numbered tabstops are unsupported";
      if !at - start > 9 then invalid "tabstop number too large";
      Int.of_string (String.sub input ~pos:start ~len:(!at - start))
    in
    let final_seen = ref false in
    while !at < length do
      match input.[!at] with
      | '\\' -> escaped literal
      | '$' ->
        flush ();
        incr at;
        let braced = !at < length && Char.equal input.[!at] '{' in
        if braced then incr at;
        let n = number () in
        let default =
          if not braced then None
          else if !at >= length then invalid "unterminated tabstop"
          else match input.[!at] with
            | '}' -> incr at; None
            | ':' ->
              if n = 0 then invalid "final cursor defaults are unsupported";
              incr at;
              let value = Buffer.create 32 in
              while !at < length && not (Char.equal input.[!at] '}') do
                match input.[!at] with
                | '\\' -> escaped value
                | '$' -> invalid "nested numbered defaults and variables are unsupported"
                | c -> Buffer.add_char value c; incr at
              done;
              if !at >= length then invalid "unterminated default";
              incr at;
              Some (Buffer.contents value)
            | _ -> invalid "choices and transformations are unsupported"
        in
        incr count;
        if !count > max_ranges then invalid "too many snippet ranges";
        if n = 0 then (
          if !final_seen then invalid "multiple final cursor markers";
          final_seen := true);
        Option.iter default ~f:(fun value ->
          match Map.find !defaults n with
          | Some old when not (String.equal old value) -> invalid "conflicting linked defaults"
          | _ -> defaults := Map.set !defaults ~key:n ~data:value);
        parts := Stop n :: !parts
      | c -> Buffer.add_char literal c; incr at
    done;
    flush ();
    let output = Buffer.create length in
    let occurrences = ref [] in
    let append s =
      if String.length s > max_output - Buffer.length output
      then invalid "snippet expansion exceeds 1048576 bytes";
      Buffer.add_string output s
    in
    List.iter (List.rev !parts) ~f:(function
      | Literal s -> append s
      | Stop number ->
        let start = Buffer.length output in
        if number <> 0 then append (Option.value (Map.find !defaults number) ~default:"");
        occurrences := { number; range = { start; stop = Buffer.length output } } :: !occurrences);
    Ok { expanded = Buffer.contents output; occurrences = List.rev !occurrences }
  with Invalid_snippet message -> Or_error.error_string message
;;

let indent t ~prefix =
  try
  if String.is_empty prefix then Ok t else
    let output = Buffer.create (String.length t.expanded) in
    let add_string value =
      if String.length value > max_input - Buffer.length output
      then invalid "indented snippet input exceeds 65536 bytes";
      Buffer.add_string output value
    in
    let add_char c =
      if Buffer.length output >= max_input
      then invalid "indented snippet input exceeds 65536 bytes";
      Buffer.add_char output c
    in
    let escaped ?(default = false) value =
      String.iter value ~f:(fun c ->
        if Char.equal c '\\' || Char.equal c '$' || (default && Char.equal c '}')
        then add_char '\\';
        add_char c;
        if Char.equal c '\n' then add_string prefix)
    in
    let at = ref 0 in
    let seen = ref Int.Set.empty in
    List.iter t.occurrences ~f:(fun o ->
      escaped (String.sub t.expanded ~pos:!at ~len:(o.range.start - !at));
      if o.number = 0 then add_string "${0}"
      else if Set.mem !seen o.number then
        add_string ("${" ^ Int.to_string o.number ^ "}")
      else (
        seen := Set.add !seen o.number;
        add_string ("${" ^ Int.to_string o.number ^ ":");
        escaped ~default:true (String.sub t.expanded ~pos:o.range.start
                   ~len:(o.range.stop - o.range.start));
        add_char '}');
      at := o.range.stop);
    escaped (String.drop_prefix t.expanded !at);
    parse (Buffer.contents output)
  with Invalid_snippet message -> Or_error.error_string message
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
              ; caret = base; revision; snapshot = text } in
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
            { edits; next = { t with length; occurrences; caret; selected = None; snapshot } }
  ;;
  let insert t ~revision ~text replacement =
    let range = Option.value t.selected ~default:{ start = t.caret; stop = t.caret } in
    replace t ~revision ~text ~start:range.start ~stop:range.stop ~replacement
  ;;
  let edits change = change.edits
  let cursor_after change = change.next.caret
  let applied change ~revision = { change.next with revision }
end
