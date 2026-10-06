open! Core
open Ches_highlight

let check ~old_source ~new_source =
  match Edit.between ~old_source ~new_source with
  | None -> [%test_result: string] old_source ~expect:new_source
  | Some edit ->
    let prefix = String.prefix old_source edit.start_byte in
    let replacement = String.sub new_source ~pos:edit.start_byte
        ~len:(edit.new_end_byte - edit.start_byte) in
    let suffix = String.drop_prefix old_source edit.old_end_byte in
    [%test_result: string] (prefix ^ replacement ^ suffix) ~expect:new_source;
    List.iter [ prefix; replacement; suffix ] ~f:(fun s -> assert (Stdlib.String.is_valid_utf_8 s));
    (* Independent line-splitting oracle, rather than the implementation's scan. *)
    let point source offset : Edit.point =
      let lines = String.split (String.prefix source offset) ~on:'\n' in
      { row = List.length lines - 1; column = String.length (List.last_exn lines) }
    in
    [%test_result: Edit.point] edit.start_point ~expect:(point old_source edit.start_byte);
    [%test_result: Edit.point] edit.old_end_point ~expect:(point old_source edit.old_end_byte);
    [%test_result: Edit.point] edit.new_end_point ~expect:(point new_source edit.new_end_byte)
;;

let%test_unit "encompassing UTF-8 replacements and independent byte points" =
  let sources =
    [ ""; "\n"; "é"; "ê"; "😀"; "😁"; "aé\nb\n"; "aê\nβ\n"
    ; "let x = 1\nlet y = 2\n"; "  let x = 1\n  let y = 2\n"
    ; "(* outer\n (* inner *) *)\n"; "end"; "end\n" ]
  in
  List.iter sources ~f:(fun old_source ->
    List.iter sources ~f:(fun new_source -> check ~old_source ~new_source));
  let random = Random.State.make [| 505 |] in
  let source () = String.concat (List.init (Random.State.int random 60)
      ~f:(fun _ -> List.nth_exn [ "a"; "é"; "ê"; "😀"; "😁"; "\n"; "\t" ] (Random.State.int random 7))) in
  for _ = 1 to 1000 do check ~old_source:(source ()) ~new_source:(source ()) done;
  assert (Exn.does_raise (fun () -> ignore (Edit.between ~old_source:"\xff" ~new_source:"" : Edit.t option)))
;;
