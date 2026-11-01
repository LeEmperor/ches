module Editor_command = Command
open! Core
module Command = Editor_command

module Policy = struct
  type t = { shift_width : int; use_tabs : bool } [@@deriving sexp_of, equal]
  let default = { shift_width = 2; use_tabs = false }
  let validate t =
    if t.shift_width <= 0 then invalid_arg "indentation shift_width must be positive"
  ;;
end

let advance column = function
  | '\t' -> column + Cell_layout.tab_stop - (column % Cell_layout.tab_stop)
  | _ -> column + 1
;;

let prefix s =
  let rec loop pos column =
    if pos < String.length s && (Char.equal s.[pos] ' ' || Char.equal s.[pos] '\t')
    then loop (pos + 1) (advance column s.[pos])
    else pos, column
  in
  loop 0 0
;;

let shifted_prefix (policy : Policy.t) ~right ~count ~skip_blank s =
  Policy.validate policy;
  if count < 1 || count > Command.max_count then invalid_arg "invalid indentation count";
  let bytes, columns = prefix s in
  if skip_blank && bytes = String.length s then None
  else (
    let target =
      if right then (
        if policy.shift_width > (Sys.max_string_length - columns) / count
        then invalid_arg "indentation is too large";
        columns + policy.shift_width * count)
      else if count > columns / policy.shift_width then 0
      else columns - policy.shift_width * count
    in
    if target = columns then None
    else
      let replacement =
        if policy.use_tabs
        then String.make (target / Cell_layout.tab_stop) '\t'
             ^ String.make (target % Cell_layout.tab_stop) ' '
        else String.make target ' '
      in
      Some replacement)
;;

let position_at_column s target =
  let rec loop pos column =
    if pos = String.length s || column >= target then pos
    else
      let next = advance column s.[pos] in
      if next > target then pos else loop (pos + 1) next
  in
  loop 0 0
;;
