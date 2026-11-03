open! Core

(* Deliberately bounded digital VCD subset. No floating-point timestamp conversion:
   all navigation and labels retain the declared timescale and integer ticks. *)
let max_bytes = 16 * 1024 * 1024
let max_tick = 1_000_000_000_000
type signal = { name : string; width : int; changes : (int * string) array }
[@@deriving sexp_of]
type t = { timescale : string; signals : signal array; last : int } [@@deriving sexp_of]

let parse text = Or_error.try_with (fun () ->
  if String.length text > max_bytes then failwith "VCD exceeds 16 MiB demo limit";
  let tokens = String.split_on_chars text ~on:[' '; '\t'; '\r'; '\n']
    |> List.filter ~f:(Fn.non String.is_empty) |> Array.of_list in
  let pos = ref 0 in
  let take () =
    if !pos >= Array.length tokens then failwith "Unexpected end of VCD";
    let value = tokens.(!pos) in incr pos; value in
  let rec directive acc = match take () with
    | "$end" -> List.rev acc | token -> directive (token :: acc) in
  let number s = match Int.of_string_opt s with
    | Some n when n >= 0 && n <= max_tick -> n
    | _ -> failwith "VCD timestamp/width out of range (maximum tick 10^12)" in
  let scopes = ref [] and declarations = ref [] and scale = ref None in
  let codes = String.Table.create () in
  let header = ref true in
  while !header do
    match take () with
    | "$date" | "$version" | "$comment" -> ignore (directive [] : string list)
    | "$timescale" ->
      let value = String.concat (directive []) in
      let valid = List.exists ["1"; "10"; "100"] ~f:(fun n ->
        List.exists ["s"; "ms"; "us"; "ns"; "ps"; "fs"] ~f:(fun unit_ ->
          String.equal value (n ^ unit_))) in
      if not valid || Option.is_some !scale then failwith "Invalid or duplicate VCD timescale";
      scale := Some value
    | "$scope" ->
      (match directive [] with
       | [_kind; name] -> scopes := name :: !scopes
       | _ -> failwith "Invalid VCD scope")
    | "$upscope" ->
      if not (List.is_empty (directive [])) || List.is_empty !scopes then failwith "Invalid VCD upscope";
      scopes := List.tl_exn !scopes
    | "$var" ->
      (match directive [] with
       | kind :: width :: code :: name :: range ->
         if not (List.mem ["wire"; "reg"; "integer"; "parameter"; "logic"; "bit"; "tri"; "tri0"; "tri1"; "wand"; "wor"; "supply0"; "supply1"] kind ~equal:String.equal)
         then failwith ("Unsupported VCD variable type: " ^ kind);
         let width = number width in
         if width < 1 || width > 4096 then failwith "VCD width must be 1..4096";
         if List.length !declarations >= 4096 then failwith "VCD exceeds 4096 signals";
         (match Hashtbl.find codes code with
          | Some (previous, _) when previous <> width -> failwith "VCD alias widths disagree"
          | Some _ -> ()
          | None -> Hashtbl.set codes ~key:code ~data:(width, ref []));
         let name = String.concat ~sep:"." (List.rev !scopes @ [name ^ String.concat range]) in
         declarations := (name, width, code) :: !declarations
       | _ -> failwith "Invalid VCD variable declaration")
    | "$enddefinitions" ->
      if not (List.is_empty (directive [])) || not (List.is_empty !scopes)
      then failwith "Invalid VCD enddefinitions";
      header := false
    | token -> failwith ("Unsupported VCD header token: " ^ token)
  done;
  let timescale = Option.value_exn !scale ~message:"VCD requires an explicit timescale" in
  let time = ref 0 and count = ref 0 and value_bytes = ref 0 in
  let change code value =
    incr count;
    if !count > 1_000_000 then failwith "VCD exceeds one million changes";
    let width, changes = match Hashtbl.find codes code with
      | Some entry -> entry | None -> failwith ("Undeclared VCD identifier: " ^ code) in
    value_bytes := !value_bytes + width;
    if !value_bytes > 64 * 1024 * 1024 then failwith "VCD exceeds 64 MiB expanded-value demo limit";
    let value = String.lowercase value in
    if String.is_empty value || not (String.for_all value ~f:(fun c -> String.mem "01xz" c))
    then failwith "Only 4-state binary VCD values are supported";
    if String.length value > width then failwith "VCD value wider than declaration";
    let fill = match value.[0] with 'x' -> 'x' | 'z' -> 'z' | _ -> '0' in
    let value = String.make (width - String.length value) fill ^ value in
    (* Last assignment wins at the same timestamp. *)
    changes := (match !changes with (at, _) :: rest when at = !time -> rest | xs -> xs);
    changes := (!time, value) :: !changes in
  while !pos < Array.length tokens do
    let token = take () in
    match token with
    | "$comment" -> ignore (directive [] : string list)
    | "$dumpvars" | "$dumpall" | "$end" -> ()
    | "$dumpoff" | "$dumpon" -> failwith "VCD dump gating is not supported (values may be unavailable)"
    | _ when String.is_prefix token ~prefix:"#" ->
      let next = number (String.drop_prefix token 1) in
      if next < !time then failwith "VCD timestamps must be monotonic";
      time := next
    | _ when String.mem "01xXzZ" token.[0] -> change (String.drop_prefix token 1) (String.prefix token 1)
    | _ when Char.equal token.[0] 'b' || Char.equal token.[0] 'B' ->
      let code = take () in change code (String.drop_prefix token 1)
    | _ -> failwith ("Unsupported VCD value/directive: " ^ token)
  done;
  (* Aliases share storage: copying a large history for every alias could multiply
     an otherwise bounded input by the declaration count. *)
  let histories = Hashtbl.map codes ~f:(fun (_, changes) -> Array.of_list_rev !changes) in
  let signals = List.rev_map !declarations ~f:(fun (name, width, code) ->
    { name; width; changes = Hashtbl.find_exn histories code }) |> Array.of_list in
  if Array.is_empty signals then failwith "VCD has no digital signals";
  { timescale; signals; last = !time })
;;

let index_at signal time =
  let lo = ref 0 and hi = ref (Array.length signal.changes) in
  while !lo < !hi do
    let mid = (!lo + !hi) / 2 in
    if fst signal.changes.(mid) <= time then lo := mid + 1 else hi := mid
  done;
  !lo - 1
;;

let value_at signal time =
  let index = index_at signal time in
  if index < 0 then String.make signal.width 'x' else snd signal.changes.(index)
;;
