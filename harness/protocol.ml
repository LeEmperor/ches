open! Core

type work = 
  { action    : string
  ; location  : string
  ; dirty     : string list 
  } [@@deriving sexp_of]
  
type run =
  { run_id        : string
  ; status        : string
  ; exit_code     : int
  ; project_root  : string
  ; log_path      : string
  ; waveform      : string option
  } [@@deriving sexp_of]

(* Variant constructors on reply type; reply is either a Created or a Finished variant 
  and has some fields of data. *)
type reply = 
  Created of 
    { root : string
    ; entry : string 
    } 
  | Finished of run
[@@deriving sexp_of]

let parse text =
  Or_error.try_with (* try to text parse and fail out an Error.t if it oofs *) 
  
  (fun () ->
    let open Yojson.Safe.Util in
    
    (* Turn string into json; yippee serialization. *)
    let json : Yojson.Safe.t = Yojson.Safe.from_string text in
    
    (* quick string helper for extraction out of the tagged variant constructors *)
    let string name : string = member name json |> to_string in
    
    match member "root" json with
      | `String root ->
        let entry = string "entry_file" in
        
        if Filename.is_relative root || 
          not (Filename.is_relative entry) || 
          List.mem (String.split entry ~on:'/') ".." ~equal:String.equal
          
        then failwith "Invalid scratch paths in qh response";
      
        (* on a string root occurrence check on filename and otherwise tagi t with proper scratch paths; 
        else created a Created reply out of the text (which is being presented as a json pack) *)
        Created 
        { root
        ; entry = Filename.concat root entry 
        }
        
      (* net match into a fail proper on runid not matching any available QH instance runs; 
        
        Or construct a Finished reply with relevant tagged metadata grouped; 
      *)
      | _ ->
      
        (* check failure for wrong runid corresponding; see if member "error" in the json payload has a message *)
        (match member "run_id" json with
         | `String _ -> ()
         | _ -> failwith (match member "error" json with
             | `String message -> message | _ -> "qh response has no run_id"
             )
        );
        
        (* else emit a Finished *)
        Finished
          { run_id        = string "run_id"
          ; status        = string "status"
          ; exit_code     = member "exit_code" json |> to_int
          ; project_root  = string "project_root"
          ; log_path      = string "log_path"
          
          (* Construct the waveform in place; if it exists return its place, otherwise return none; *)
          (* 
              member : string -> t -> t = 
                fun k obj -> 
                ...
              returns the value asssocaited with key k in the json obj 
              
              This is an example of an artifact in artifacts record as a json obj, which has members inside of it;
                Artifact.t (not a real type but conceptually think of it like that)
                
                Each Artifact.t has a "kind" which we're checking to be "waveform", and if it is,
                  we wrap a Some onto the "path" member the artifact of kind waveform has.
              [
                {
                  "kind": "waveform",
                  "path": "/tmp/waves.vcd"
                }
              ]
          *)
          ; waveform      = member "artifacts" json   (* out of the json object json, we extract the field "artifacts" out of *)
                |> to_list                            (* convert the artifacts item into a list; *)
                |> List.find_map ~f:(fun item ->      (* find the first non-None occurrence *)
                    if String.equal (member "kind" item |> to_string) "waveform" (* if there is a "waveform" kind existing *)
                      then Some (member "path" item |> to_string) (* then construct a Some on the path belonging to the artifact *)
                    else None
                  )
          }
    )
;;
