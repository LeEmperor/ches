open! Core
open Ches_source

let%test_unit "module identity uses enclosing definitions rather than nested Slang instantiation symbols" =
  let point character = `Assoc ["line", `Int 0; "character", `Int character] in
  let range start stop = `Assoc ["start", point start; "end", point stop] in
  let symbol name start stop children = `Assoc ["name", `String name; "kind", `Int 2;
    "range", range start stop; "children", `List children] in
  let symbols = `List [symbol "leaf" 0 10 [];
    symbol "top" 10 40 [symbol "leaf" 20 30 []];
    `Assoc ["name", `String "foreign"; "kind", `Int 2;
      "location", `Assoc ["uri", `String "file:///included.svh"; "range", range 0 40];
      "children", `List [symbol "included_child" 12 39 []]]] in
  List.iter [0, ["leaf"]; 10, ["top"]; 25, ["top"]; 39, ["top"]; 40, []]
    ~f:(fun (character, expected) ->
      let candidates = Instance_wire.modules ~uri:"file:///source.sv"
        ~position:{line = 0; character} symbols in
      assert ([%equal: string list] (List.map candidates ~f:fst) expected))

let%test_unit "standard reference arrays preserve zero one and many locations with exact encoding" =
  let point character = `Assoc ["line", `Int 0; "character", `Int character] in
  let location character = `Assoc ["uri", `String "file:///tmp/dirty%20target.sv";
    "range", `Assoc ["start", point character; "end", point (character + 1)]] in
  List.iter [0; 1; 3] ~f:(fun count ->
    match Navigation_wire.decode Utf16 References (`List (List.init count ~f:location)) with
    | Ok (Locations targets) ->
      assert (List.length targets = count);
      List.iteri targets ~f:(fun character target ->
        assert (String.equal target.path "/tmp/dirty target.sv");
        assert (target.selection.start.character = character);
        assert (Ches_error.Language_query.equal_encoding target.encoding Utf16))
    | _ -> assert false)
