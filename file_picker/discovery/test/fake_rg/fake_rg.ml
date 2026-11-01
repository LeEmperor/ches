open! Core

let emit path = Out_channel.output_string stdout (path ^ "\000"); Out_channel.flush stdout

(* Tests poll for [pid] while children run, so it must never be observable half-written. *)
let write_atomic dst ~data =
  let tmp = sprintf ".%s.%d.tmp" dst (Pid.to_int (Core_unix.getpid ())) in
  Out_channel.write_all tmp ~data; Core_unix.rename ~src:tmp ~dst
;;

let () =
  write_atomic "pid" ~data:(Pid.to_string (Core_unix.getpid ()));
  match In_channel.read_all "mode" with
  | "ordered" ->
    List.iter [ "z"; "a\n\255"; "z"; "b/main.ml"; "a/main.ml"; ".hidden"; ".git/config" ] ~f:emit
  | "fragmented" -> emit ("./dir/" ^ String.make 3000 'a' ^ "/" ^ String.make 3000 'b' ^ "\n\255")
  | "partial-failure" ->
    emit "before";
    Out_channel.output_string stderr ("denied\n\027\000" ^ String.make 100_000 'x');
    exit 2
  | "missing-nul" -> Out_channel.output_string stdout "bad"
  | "invalid" -> emit "../escape"
  | "long" -> emit (String.make 10_000 'x')
  | "empty" -> exit 1
  | "stall" -> Core_unix.sleep 60
  | "pushback" -> for i = 0 to 10_000 do emit (Int.to_string i) done; Core_unix.sleep 60
  | "duplicates" -> for _ = 0 to 10_000 do emit "same" done
  | _ -> exit 2
