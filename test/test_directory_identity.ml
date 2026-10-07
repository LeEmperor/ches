open! Core
open Ches_core
module D = Directory_identity

let text s =
  Text_buffer.of_string s
  |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum
  |> Result.ok_or_failwith
;;
let baseline =
  D.create
    [ { id = 1; name = "alpha"; kind = File }
    ; { id = 2; name = "folder"; kind = Directory }
    ; { id = 3; name = "link"; kind = Symlink }
    ]
  |> Or_error.ok_exn
;;

let rows s = D.parse baseline (text s) |> Or_error.ok_exn
let ids rows = List.map rows ~f:(fun row -> row.D.Row.identity)
let initial = "@ches[1]\talpha\n@ches[2]\tfolder/\n@ches[3]\tlink"
let editor () = Editor.create ~cell_width:Cell_width.f (D.text baseline)

let run editor commands =
  List.fold commands ~init:editor ~f:(fun editor command ->
    let editor, effects = Editor.dispatch editor command in
    (* The spike never requests filesystem IO, even for invalid text. *)
    assert (List.for_all effects ~f:(function Effect.Set_clipboard _ -> true | _ -> false));
    editor)
;;

let parsed editor = D.parse baseline (Editor.text editor) |> Or_error.ok_exn
let contents editor = Text_buffer.to_string (Editor.text editor)

let%test_unit "baseline serialization and byte-name codec are lossless" =
  assert (String.equal (Text_buffer.to_string (D.text baseline)) initial);
  assert ([%equal: D.Row.identity list] (ids (rows initial)) [ Existing 1; Existing 2; Existing 3 ]);
  (* Every legal byte, including CR, LF, TAB, and invalid UTF-8, individually and
     together. The serialized surface must always be valid editor text. *)
  let names =
    List.init 255 ~f:(fun i -> Char.of_int_exn (i + 1))
    |> List.filter ~f:(fun c -> not (Char.equal c '/'))
    |> List.map ~f:(fun c -> "a" ^ String.of_char c ^ "z")
  in
  List.iter (String.concat names :: "@ches[999]\tpretend" :: " space " :: names) ~f:(fun name ->
    let encoded = D.encode_name name in
    assert (Result.is_ok (Text_buffer.validate encoded));
    assert (String.equal name (D.decode_name encoded |> Or_error.ok_exn));
    let baseline = D.create [ { id = 1; name; kind = File } ] |> Or_error.ok_exn in
    let restored = D.parse baseline (D.text baseline) |> Or_error.ok_exn |> List.hd_exn in
    assert (String.equal restored.name name));
  assert (String.equal (D.encode_name "a\t\n\r\255\\@") "a\\x09\\x0A\\x0D\\xFF\\x5C\\x40")
;;

let%test_unit "ordinary name editing preserves backing identity through undo redo" =
  let original = editor () in
  let renamed = run original
    [ Enter_insert Line_end
    ; Delete_backward; Delete_backward; Delete_backward; Delete_backward; Delete_backward
    ; Insert_text "renamed"; Exit_insert
    ] in
  let row = List.hd_exn (parsed renamed) in
  assert ([%equal: D.Row.identity] row.identity (Existing 1));
  assert (String.equal row.name "renamed");
  let undone = run renamed [ Undo ] in
  assert (String.equal (contents undone) initial);
  let redone = run undone [ Redo ] in
  assert ([%equal: D.Row.t list] (parsed redone) (parsed renamed));
  assert (Editor.revision redone > Editor.revision renamed)
;;

let%test_unit "fresh line paste and deletion are distinct from existing identity" =
  let created = run (editor ()) [ Open_line_below; Insert_text "fresh"; Exit_insert ] in
  assert ([%equal: D.Row.identity list] (ids (parsed created))
    [ Existing 1; Fresh; Existing 2; Existing 3 ]);
  assert (List.is_empty (D.missing_ids baseline (parsed created)));
  assert (String.equal (contents (run created [ Undo ])) initial);
  assert ([%equal: D.Row.identity list] (ids (parsed (run (run created [ Undo ]) [ Redo ])))
    [ Existing 1; Fresh; Existing 2; Existing 3 ]);
  let deleted = run (editor ()) [ Delete_lines 1 ] in
  assert ([%equal: int list] (D.missing_ids baseline (parsed deleted)) [ 1 ]);
  assert ([%equal: D.Row.identity list] (ids (parsed deleted)) [ Existing 2; Existing 3 ]);
  assert (String.equal (contents (run deleted [ Undo ])) initial);
  let pasted = run (editor ())
    [ Enter_insert Before_cursor; Insert_text "fresh\n"; Exit_insert ] in
  assert ([%equal: D.Row.identity list] (ids (parsed pasted))
    [ Fresh; Existing 1; Existing 2; Existing 3 ])
;;

let%test_unit "yank paste duplication is rejected and undo restores validity" =
  let duplicate = run (editor ()) [ Yank_lines 1; Paste { before = false; count = 1 } ] in
  assert (Result.is_error (D.parse baseline (Editor.text duplicate)));
  assert (String.equal (contents (run duplicate [ Undo ])) initial);
  assert (Result.is_error (D.parse baseline (Editor.text (run (run duplicate [ Undo ]) [ Redo ]))))
;;

let%test_unit "whole row movement and multiline replacement keep identities not row numbers" =
  let moved = run (editor ())
    [ Delete_lines 1; Move { motion = Last_line; count = None }
    ; Paste { before = false; count = 1 }
    ] in
  assert ([%equal: D.Row.identity list] (ids (parsed moved)) [ Existing 2; Existing 3; Existing 1 ]);
  assert (List.is_empty (D.missing_ids baseline (parsed moved)));
  let replaced = run (editor ())
    [ Enter_visual `Linewise; Move { motion = Last_line; count = None }; Visual_change
    ; Insert_text "@ches[3]\tlink\nnew/\n@ches[1]\tother\n@ches[2]\tfolder/"
    ; Exit_insert
    ] in
  assert ([%equal: D.Row.identity list] (ids (parsed replaced))
    [ Existing 3; Fresh; Existing 1; Existing 2 ]);
  assert (String.equal (contents (run replaced [ Undo ])) initial);
  assert ([%equal: D.Row.t list] (parsed (run (run replaced [ Undo ]) [ Redo ])) (parsed replaced))
;;

let%test_unit "join split and invalid token edits cannot validate" =
  (* Backspace at the next row's start joins rows using the real editor. *)
  let joined = run (editor ())
    [ Move { motion = Down; count = None }; Move { motion = Line_start; count = None }
    ; Enter_insert Before_cursor; Delete_backward; Exit_insert
    ] in
  assert (Result.is_error (D.parse baseline (Editor.text joined)));
  assert (String.equal (contents (run joined [ Undo ])) initial);
  let damaged = run (editor ()) [ Delete_char ] in
  assert (Result.is_error (D.parse baseline (Editor.text damaged)));
  let split = run (editor ())
    [ Enter_insert After_cursor; Insert_newline; Exit_insert ] in
  assert (Result.is_error (D.parse baseline (Editor.text split)));
  assert (String.equal (contents (run split [ Undo ])) initial);
  List.iter
    [ "@ches[99]\tname"; "@ches[01]\talpha"; "@ches[1] alpha"
    ; "@ches[1]\talpha@ches[2]\tfolder/"; "@ches[1]\talpha/"
    ; "@ches[1]\nalpha"; "@ches[1]\t"
    ; "@ches[1]\ta\\x00b"; "@ches[1]\ta\\x2Fb"; "\\x61lpha"
    ; "\\xFF\\xff"; "new\\"; "."; ".."; "nested/name"; "@filename"
    ]
    ~f:(fun raw -> assert (Result.is_error (D.parse baseline (text raw))))
;;

let%test_unit "identity-like names are escaped; spaces and blank rows are unambiguous" =
  let name = "@ches[1]\talpha" in
  let row = rows (D.encode_name name) |> List.hd_exn in
  assert ([%equal: D.Row.identity] row.identity Fresh);
  assert (String.equal row.name name);
  let parsed = rows ("\n" ^ initial ^ "\n\n\\x20name\\x20\n") in
  assert (List.length parsed = 4);
  assert (String.equal (List.last_exn parsed).name " name ");
  assert ([%equal: int list] (D.missing_ids baseline (rows "")) [ 1; 2; 3 ])
;;

let%test_unit "unsupported entries remain visible and read only; symlink type stays link" =
  let baseline = D.create [ { id = 4; name = "pipe\255"; kind = Unsupported } ] |> Or_error.ok_exn in
  assert (Result.is_ok (D.parse baseline (D.text baseline)));
  assert (Result.is_error (D.parse baseline (text "@ches[4]\trename")));
  assert (Result.is_error (D.parse baseline Text_buffer.empty));
  let link = rows "@ches[3]\tother" |> List.hd_exn in
  assert (D.Kind.equal link.kind Symlink);
  assert (Result.is_error (D.create [ { id = 0; name = "x"; kind = File } ]));
  assert (Result.is_error (D.create
    [ { id = 1; name = "a"; kind = File }; { id = 1; name = "b"; kind = File } ]))
;;
