open! Core

type work = { action : string; location : string; dirty : string list } [@@deriving sexp_of]
type run =
  { run_id : string
  ; status : string
  ; exit_code : int
  ; project_root : string
  ; log_path : string
  ; waveform : string option
  }
[@@deriving sexp_of]

type reply = Created of { root : string; entry : string } | Finished of run
[@@deriving sexp_of]

let parse text =
  Or_error.try_with (fun () ->
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_string text in
    let string name = member name json |> to_string in
    match member "root" json with
    | `String root ->
      let entry = string "entry_file" in
      if Filename.is_relative root || not (Filename.is_relative entry)
         || List.mem (String.split entry ~on:'/') ".." ~equal:String.equal
      then failwith "Invalid scratch paths in qh response";
      Created { root; entry = Filename.concat root entry }
    | _ ->
      (match member "run_id" json with
       | `String _ -> ()
       | _ -> failwith (match member "error" json with
           | `String message -> message | _ -> "qh response has no run_id"));
      Finished
        { run_id = string "run_id"; status = string "status"
        ; exit_code = member "exit_code" json |> to_int
        ; project_root = string "project_root"; log_path = string "log_path"
        ; waveform = member "artifacts" json |> to_list |> List.find_map ~f:(fun item ->
            if String.equal (member "kind" item |> to_string) "waveform"
            then Some (member "path" item |> to_string) else None)
        })
;;
