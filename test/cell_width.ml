open! Core

(* A small stand-in for the terminal's width table, which these tests cannot depend
   on: combining diacritics are 0 cells, CJK ideographs 2, everything else 1. *)
let f u =
  match Uchar.to_scalar u with
  | c when c >= 0x0300 && c <= 0x036F -> 0
  | c when c >= 0x4E00 && c <= 0x9FFF -> 2
  | _ -> 1
;;
