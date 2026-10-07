open! Core
open Ches_core

let entries =
  [ { Directory_identity.Entry.id = 1; name = "a"; kind = File }
  ; { Directory_identity.Entry.id = 2; name = "b"; kind = Directory }
  ; { Directory_identity.Entry.id = 3; name = "link"; kind = Symlink }
  ]
let text s = Text_buffer.of_string s |> Result.map_error ~f:Text_buffer.Invalid_text.to_string_hum |> Result.ok_or_failwith
let plan s = Directory_plan.plan entries (text s)

let%test_unit "pure planner creates, renames symlinks, reorders, and accepts rename dependencies" =
  let operations = plan "@ches[2]\tb/\nnew\nfolder/\n@ches[1]\tc\n@ches[3]\talias" |> Or_error.ok_exn in
  assert (List.equal Directory_plan.equal_operation operations
    [ Create_file "new"; Create_directory "folder"
    ; Rename { id = 1; source = "a"; destination = "c" }
    ; Rename { id = 3; source = "link"; destination = "alias" } ]);
  assert (String.is_substring (Directory_plan.summary operations) ~substring:"Rename link -> alias");
  assert (List.is_empty (plan "@ches[3]\tlink\n\n@ches[2]\tb/\n@ches[1]\ta\n" |> Or_error.ok_exn));
  assert (List.length (plan "@ches[1]\tb\n@ches[2]\ta/\n@ches[3]\tlink" |> Or_error.ok_exn) = 2)
;;

let%test_unit "unsupported or ambiguous snapshots reject the entire proposal" =
  List.iter
    [ "@ches[1]\ta\n@ches[2]\tb/\n@ches[3]\tlink\n@ches[1]\tcopy"
    ; "@ches[1]\tb\n@ches[2]\tb/\n@ches[3]\tlink" (* occupied destination *)
    ; "@ches[1]\ta\n@ches[2]\tb/\n@ches[3]\tlink\na" (* create collision *)
    ; "@ches[1]\ta/\n@ches[2]\tb/\n@ches[3]\tlink" (* type change *)
    ; "@ches[99]\ta\n@ches[2]\tb/\n@ches[3]\tlink"
    ; "@ches[1]\ta\n@ches[2]\tb/\n@ches[3]\tlink\n../escape"
    ; "@ches[1]\ta\n@ches[2]\tb/\n@ches[3]\tlink\n\\x00"
    ; "@ches[1]\ta\n@ches[2]\tb/\n@ches[3]\tlink\nnew\nnew/"
    ] ~f:(fun snapshot -> assert (Result.is_error (plan snapshot)))
;;

let%test_unit "phase8 explicit copied rows have source identity independent of deletion and moves" =
  let operations = plan "@ches[2]\tb/\n@ches[3]\t../other/link\n@copy[1]\tcopy\n@copy[1]\t../other/copy" |> Or_error.ok_exn in
  assert (List.equal Directory_plan.equal_operation operations
    [ Delete { id = 1; source = "a"; kind = File }
    ; Rename { id = 3; source = "link"; destination = "../other/link" }
    ; Copy { id = 1; source = "a"; destination = "copy"; kind = File }
    ; Copy { id = 1; source = "a"; destination = "../other/copy"; kind = File } ]);
  assert (String.is_substring (Directory_plan.summary operations) ~substring:"Permanently delete");
  assert (Result.is_error (plan "@copy[99]\tcopy"));
  assert (Result.is_error (plan "@ches[1]\ta\n@ches[2]\tb/\n@ches[3]\tlink\n@copy[2]\tcopy"));
  assert (Result.is_error (plan "@ches[1]\ta\n@ches[2]\tb/\n@ches[3]\tlink\n@copy[1]\tcopy\n@copy[1]\tcopy"))
;;
