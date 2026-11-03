open! Core
open Ches_core
module B = Text_buffer

type declaration =
  { id : string
  ; prefix : string
  ; scopes : string list
  ; description : string option
  ; body : string
  }
[@@deriving sexp, equal]

type origin = Bundled | Legacy_json | Ocaml [@@deriving sexp, equal]
type item = { declaration : declaration; origin : origin }
[@@deriving sexp, equal]

type entry = { item : item; template : Snippet.t }
type t = entry String.Map.t

type operation = Add of declaration | Disable of string
[@@deriving sexp, equal]

let starter id prefix description body =
  { item = { declaration = { id; prefix; scopes = [ "systemverilog" ]; description = Some description; body }
           ; origin = Bundled }
  ; template = Snippet.parse body |> Or_error.ok_exn }
;;

let builtins =
  [ starter "sv.aff" "aff" "Clocked always block"
      "always_ff @(${1|posedge,negedge|} ${2:clk}) begin\n    $0\nend"
  ; starter "sv.acomb" "acomb" "Combinational always block"
      "always_comb begin\n    $0\nend"
  ; starter "sv.mod" "mod" "Module declaration"
      "module ${1:${TM_FILENAME_BASE:module_name}} (\n    $0\n);\nendmodule"
  ; starter "sv.inst" "inst" "Module instance"
      "${1:module_name} ${2:instance_name} (\n    .${3:port}($3)$0\n);"
  ; starter "sv.genfor" "genfor" "Generate loop"
      "for (genvar ${1:i} = 0; $1 < ${2:COUNT}; $1++) begin : ${3:gen_block}\n    $0\nend"
  ]
  |> List.map ~f:(fun entry -> entry.item.declaration.id, entry)
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

let validate_string name value =
  match B.validate value with
  | Ok () -> value
  | Error error -> invalid (name ^ ": " ^ B.Invalid_text.to_string_hum error)
;;

let string name = function
  | `String value -> validate_string name value
  | _ -> invalid (name ^ " must be a string")
;;

let nonempty_string name value =
  let value = validate_string name value in
  if String.is_empty (String.strip value) then invalid (name ^ " must be nonempty");
  value
;;

let nonempty name value = nonempty_string name (string name value)

let validate_scope value =
  let value = nonempty_string "scope" value in
  if List.mem [ "systemverilog"; "verilog"; "ocaml" ] value ~equal:String.equal
     || (String.is_prefix value ~prefix:"." && String.length value > 1
         && not (String.exists value ~f:(fun c ->
           Char.is_whitespace c || Char.equal c '/' || Char.equal c '\\')))
  then value
  else invalid ("unsupported scope " ^ value
                ^ "; use systemverilog, verilog, ocaml, or a .filename-extension")
;;

let scope value = validate_scope (string "scope" value)
let validate_id id = nonempty_string "id" id

let declaration_entry ~origin ({ id; prefix; scopes; description; body } : declaration) : entry =
  let id = validate_id id in
  let prefix = nonempty_string "prefix" prefix in
  let scopes = List.map scopes ~f:validate_scope in
  let description = Option.map description ~f:(validate_string "description") in
  let template = match Snippet.parse body with
    | Ok template -> template
    | Error error -> invalid ("body: " ^ Error.to_string_hum error)
  in
  { item = { declaration = { id; prefix; scopes; description; body }; origin }; template }
;;

let apply base operations =
  try
    if List.length operations > 1000 then invalid "snippets exceeds 1000 operations";
    let bytes = ref 0 in
    let count value =
      if String.length value > 1_048_576 - !bytes then
        invalid "snippet declarations exceed 1 MiB";
      bytes := !bytes + String.length value
    in
    Ok (List.foldi operations ~init:base ~f:(fun index catalog operation ->
      let id = match operation with Add declaration -> declaration.id | Disable id -> id in
      try
        count id;
        ignore (validate_id id : string);
        match operation with
        | Disable id -> Map.remove catalog id
        | Add declaration ->
          count declaration.prefix;
          List.iter declaration.scopes ~f:count;
          Option.iter declaration.description ~f:count;
          count declaration.body;
           let entry = declaration_entry ~origin:Ocaml declaration in
          Map.set catalog ~key:id ~data:entry
      with Invalid_config message ->
        invalid (sprintf "snippets[%d] (%s): %s" index id message)))
  with Invalid_config message -> Or_error.error_string message
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
           let entry = declaration_entry ~origin:Legacy_json { id; prefix; scopes; description; body } in
          Map.set catalog ~key:id ~data:entry)
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

let applicable (declaration : declaration) ~path =
  List.is_empty declaration.scopes
  || Option.exists path ~f:(fun path ->
    List.exists declaration.scopes ~f:(fun scope -> matches_scope scope path))
;;

let entries t ~path =
  Map.data t
  |> List.filter ~f:(fun entry -> applicable entry.item.declaration ~path)
  |> List.sort ~compare:(fun a b ->
    let a = a.item.declaration and b = b.item.declaration in
    match String.compare a.prefix b.prefix with
    | 0 -> String.compare a.id b.id
    | comparison -> comparison)
;;

let available t ~path = List.map (entries t ~path) ~f:(fun entry -> entry.item)

let candidate entry ~path ~text ~start ~cursor =
  let line = B.line_start text (B.line_of_offset text start) in
  let rec whitespace_end at =
    if at < start && (match Uchar.to_scalar (B.uchar_at text at) with
      | 32 | 9 -> true | _ -> false)
    then whitespace_end (at + 1) else at
  in
  let indentation = B.slice text ~pos:line ~len:(whitespace_end line - line) in
  let%map.Or_error snippet =
    Or_error.bind (Snippet.resolve entry.template ~path)
      ~f:(fun template -> Snippet.indent template ~prefix:indentation)
  in
  let declaration = entry.item.declaration in
  { Model.Candidate.id = "user-snippet:" ^ declaration.id; source = Snippet
  ; label = declaration.prefix; detail = declaration.description
  ; filter_text = declaration.prefix; sort_text = declaration.prefix
  ; primary = { Text_edit.start; stop = cursor; text = Snippet.text snippet }
  ; additional = []; cursor = Snippet.final_cursor snippet; snippet = Some snippet }
;;

let instantiate t ~id ~path ~text ~cursor =
  if not (B.is_boundary text cursor) then Or_error.error_string "Invalid snippet insertion cursor"
  else match Map.find t id with
  | None -> Or_error.errorf "Unknown snippet ID: %s" id
  | Some entry when not (applicable entry.item.declaration ~path) ->
    Or_error.errorf "Snippet %s is not applicable to this path" id
  | Some entry -> candidate entry ~path ~text ~start:cursor ~cursor
;;

let candidates (t : t) ~path ~text ~cursor ~limit =
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
       entries t ~path
       |> List.filter ~f:(fun entry -> String.is_prefix entry.item.declaration.prefix ~prefix)
      |> Sequence.of_list
       |> Sequence.filter_map ~f:(fun entry ->
         candidate entry ~path ~text ~start ~cursor |> Result.ok)
      |> Fn.flip Sequence.take limit
      |> Sequence.to_list
;;
