open! Core
let bytes s = `Assoc [ "bytes", `String (Base64.encode_exn s) ]
let record ?(path = "./odd\n\255") ?(text = "界\tneedle needle\255\n") ?(line = 3) () =
  let sub start = `Assoc [ "start", `Int start; "end", `Int (start + 6); "match", bytes "needle" ] in
  `Assoc [ "type", `String "match"; "data", `Assoc
    [ "path", bytes path; "lines", bytes text; "line_number", `Int line
    ; "submatches", `List [ sub 4; sub 11 ] ] ]
  |> Yojson.Basic.to_string
;;
let emit s = Out_channel.output_string stdout (s ^ "\n"); Out_channel.flush stdout
(* Tests poll for these files while children are spawned and replaced, so they must never be
   observable half-written: write a per-process temp file and rename it into place. *)
let write_atomic dst ~data =
  let tmp = sprintf ".%s.%d.tmp" dst (Pid.to_int (Core_unix.getpid ())) in
  Out_channel.write_all tmp ~data; Core_unix.rename ~src:tmp ~dst
;;
let () =
  write_atomic "pid" ~data:(Pid.to_string (Core_unix.getpid ()));
  write_atomic "args" ~data:(String.concat ~sep:"\n" (Array.to_list (Sys.get_argv ())));
  match In_channel.read_all "mode" with
  | "normal" -> emit (record ())
  | "invalid-path" -> emit (record ~path:"../outside" ())
  | "invalid-offset" -> emit (record ~text:"x" ())
  | "malformed" -> emit "{oops"
  | "unterminated" -> Out_channel.output_string stdout (record ())
  | "long" -> emit (String.make 100_000 'x')
  | "long-path" -> emit (record ~path:(String.make 4097 'p') ())
  | "empty" -> exit 1
  | "failure" -> emit (record ()); Out_channel.output_string stderr ("denied\n\027\000" ^ String.make 100_000 'x'); exit 2
  | "stall" -> Core_unix.sleep 60
  | "pushback" -> for i = 1 to 100_000 do emit (record ~line:i ()) done; Core_unix.sleep 60
  | "hidden" -> emit (record ~path:".git/config" ()); emit (record ~path:".hidden" ()); emit (record ())
  | _ -> exit 2
