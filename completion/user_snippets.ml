open! Core
open Ches_core
module B = Text_buffer

type entry =
  { id : string
  ; prefix : string
  ; scopes : string list
  ; description : string option
  ; template : Snippet.t
  }

type t = entry String.Map.t

let starter id prefix description body =
  { id; prefix; scopes = [ "systemverilog" ]; description = Some description
  ; template = Snippet.parse body |> Or_error.ok_exn }
;;

let builtins =
  [ starter "sv.aff" "aff" "Clocked always block"
      "always_ff @(posedge ${1:clk}) begin\n    $0\nend"
  ; starter "sv.acomb" "acomb" "Combinational always block"
      "always_comb begin\n    $0\nend"
  ; starter "sv.mod" "mod" "Module declaration"
      "module ${1:name} (\n    $0\n);\nendmodule"
  ; starter "sv.inst" "inst" "Module instance"
      "${1:module_name} ${2:instance_name} (\n    .${3:port}($3)$0\n);"
  ; starter "sv.genfor" "genfor" "Generate loop"
      "for (genvar ${1:i} = 0; $1 < ${2:COUNT}; $1++) begin : ${3:gen_block}\n    $0\nend"
  ]
  |> List.map ~f:(fun entry -> entry.id, entry)
  |> String.Map.of_alist_exn
;;

exception Invalid_config of string
let invalid message = raise (Invalid_config message)

let object_fields = function
  | `Assoc fields ->
    let names = List.map fields ~f:fst in
    (match List.find_a_dup names ~compare:String.compare with
     | Some name -> invalid ("duplicate field " ^ name)
     | None -> ());
    fields
  | _ -> invalid "expected an object"
;;

let check_fields fields allowed =
  List.iter fields ~f:(fun (name, _) ->
    if not (List.mem allowed name ~equal:String.equal)
    then invalid ("unknown field " ^ name))
;;

let find fields key = List.Assoc.find fields key ~equal:String.equal
let required fields key =
  match find fields key with Some value -> value | None -> invalid ("missing " ^ key)
;;

let string name = function
  | `String value ->
    (match B.validate value with
     | Ok () -> value
     | Error error -> invalid (name ^ ": " ^ B.Invalid_text.to_string_hum error))
  | _ -> invalid (name ^ " must be a string")
;;

let nonempty name value =
  let value = string name value in
  if String.is_empty (String.strip value) then invalid (name ^ " must be nonempty");
  value
;;

let scope value =
  let value = nonempty "scope" value in
  if List.mem [ "systemverilog"; "verilog"; "ocaml" ] value ~equal:String.equal
     || (String.is_prefix value ~prefix:"." && String.length value > 1
         && not (String.exists value ~f:(fun c ->
           Char.is_whitespace c || Char.equal c '/' || Char.equal c '\\')))
  then value
  else invalid ("unsupported scope " ^ value
                ^ "; use systemverilog, verilog, ocaml, or a .filename-extension")
;;

let parse input =
  try
    if String.length input > 1_048_576 then invalid "snippets file exceeds 1 MiB";
    let json =
      try Yojson.Basic.from_string input with
      | Yojson.Json_error message -> invalid ("invalid snippets JSON: " ^ message)
    in
    let fields = object_fields json in
    check_fields fields [ "version"; "snippets" ];
    (match required fields "version" with
     | `Int 1 -> ()
     | _ -> invalid "version must be the integer 1");
    let entries = match required fields "snippets" with
      | `List entries -> entries
      | _ -> invalid "snippets must be an array"
    in
    if List.length entries > 1000 then invalid "snippets exceeds 1000 entries";
    let seen = ref String.Set.empty in
    Ok (List.foldi entries ~init:builtins ~f:(fun index catalog json ->
      let context = ref ("snippets[" ^ Int.to_string index ^ "]") in
      try
        let fields = object_fields json in
        let id = nonempty "id" (required fields "id") in
        context := !context ^ " (" ^ id ^ ")";
        if Set.mem !seen id then invalid "duplicate user id";
        seen := Set.add !seen id;
        let disabled = match find fields "disabled" with
          | None | Some (`Bool false) -> false
          | Some (`Bool true) -> true
          | Some _ -> invalid "disabled must be a boolean"
        in
        if disabled then (
          check_fields fields [ "id"; "disabled" ];
          Map.remove catalog id)
        else (
          check_fields fields [ "id"; "prefix"; "scope"; "description"; "body"; "disabled" ];
          let prefix = nonempty "prefix" (required fields "prefix") in
          let scopes = match find fields "scope" with
            | None -> []
            | Some (`List scopes) -> List.map scopes ~f:scope
            | Some _ -> invalid "scope must be an array"
          in
          let description = Option.map (find fields "description") ~f:(string "description") in
          let body = match required fields "body" with
            | `String body -> body
            | `List lines -> String.concat ~sep:"\n" (List.map lines ~f:(string "body line"))
            | _ -> invalid "body must be a string or array of strings"
          in
          let template = match Snippet.parse body with
            | Ok template -> template
            | Error error -> invalid ("body: " ^ Error.to_string_hum error)
          in
          Map.set catalog ~key:id ~data:{ id; prefix; scopes; description; template })
      with Invalid_config message -> invalid (!context ^ ": " ^ message)))
  with Invalid_config message -> Or_error.error_string message
;;

let matches_scope scope path =
  let extensions = match scope with
    | "systemverilog" -> [ ".sv"; ".svh" ]
    | "verilog" -> [ ".v"; ".vh" ]
    | "ocaml" -> [ ".ml"; ".mli" ]
    | extension -> [ extension ]
  in
  List.exists extensions ~f:(fun suffix -> String.is_suffix path ~suffix)
;;

let candidates t ~path ~text ~cursor ~limit =
  if limit <= 0 || not (B.is_boundary text cursor) then [] else
    let rec prefix_start at =
      match B.prev_boundary text at with
      | Some before when Poly.equal (Search_match.small_word_class text before) (Some `Identifier) ->
        if cursor - before > 4096 then None else prefix_start before
      | _ -> Some at
    in
    match prefix_start cursor with
    | None -> []
    | Some start ->
      let prefix = B.slice text ~pos:start ~len:(cursor - start) in
      let line = B.line_start text (B.line_of_offset text start) in
      let rec whitespace_end at =
        if at < start && (match Uchar.to_scalar (B.uchar_at text at) with
          | 32 | 9 -> true | _ -> false)
        then whitespace_end (at + 1) else at
      in
      let indentation = B.slice text ~pos:line ~len:(whitespace_end line - line) in
      Map.data t
      |> List.filter ~f:(fun entry ->
        String.is_prefix entry.prefix ~prefix
        && (List.is_empty entry.scopes
            || Option.exists path ~f:(fun path -> List.exists entry.scopes ~f:(fun scope ->
              matches_scope scope path))))
      |> List.sort ~compare:(fun a b ->
        match String.compare a.prefix b.prefix with
        | 0 -> String.compare a.id b.id
        | comparison -> comparison)
      |> Sequence.of_list
      |> Sequence.filter_map ~f:(fun entry ->
        match Snippet.indent entry.template ~prefix:indentation with
        | Error _ -> None
        | Ok snippet ->
          let expanded = Snippet.text snippet in
          Some { Model.Candidate.id = "user-snippet:" ^ entry.id; source = Snippet
               ; label = entry.prefix; detail = entry.description
               ; filter_text = entry.prefix; sort_text = entry.prefix
               ; primary = { Text_edit.start; stop = cursor; text = expanded }
               ; additional = []; cursor = Snippet.final_cursor snippet
               ; snippet = Some snippet })
      |> Fn.flip Sequence.take limit
      |> Sequence.to_list
;;
