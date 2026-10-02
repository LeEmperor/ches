open! Core
open Bonsai_term

module Role = struct
  type t =
    | Background
    | Foreground
    | Surface
    | Muted
    | Border
    | Current_line
    | Normal_accent
    | Insert_accent
    | Special
    | Warning
    | Error
  [@@deriving sexp_of, enumerate]

  let color t =
    let r, g, b =
      match t with
      | Background -> 0x1a, 0x1b, 0x26
      | Foreground -> 0xc0, 0xca, 0xf5
      | Surface -> 0x24, 0x28, 0x3b
      | Muted -> 0x56, 0x5f, 0x89
      | Border -> 0x3b, 0x42, 0x61
      | Current_line -> 0x29, 0x2e, 0x42
      | Normal_accent -> 0x7a, 0xa2, 0xf7
      | Insert_accent -> 0x9e, 0xce, 0x6a
      | Special -> 0xbb, 0x9a, 0xf7
      | Warning -> 0xe0, 0xaf, 0x68
      | Error -> 0xf7, 0x76, 0x8e
    in
    Attr.Color.rgb ~r ~g ~b
  ;;
end

let attrs (style : Ches_screen.Style.t) =
  let colors ?(attrs = []) fg bg =
    Attr.fg (Role.color fg) :: Attr.bg (Role.color bg) :: attrs
  in
  match style with
  | Backdrop -> colors Foreground Background
  | Text -> colors Foreground Background
  | Text_cursor_line -> colors Foreground Current_line
  | Special -> colors Special Background
  | Special_cursor_line -> colors Special Current_line
  | Gutter -> colors Muted Background
  | Gutter_cursor_line -> colors Foreground Current_line
  | Border -> colors Border Background
  | Status -> colors Foreground Surface
  | Status_special -> colors Special Surface
  | Mode Normal -> colors ~attrs:[ Attr.bold ] Background Normal_accent
  | Mode Insert -> colors ~attrs:[ Attr.bold ] Background Insert_accent
  | Dirty -> colors ~attrs:[ Attr.bold ] Warning Surface
  | Pending -> colors ~attrs:[ Attr.bold ] Normal_accent Surface
  | Info -> colors Foreground Surface
  | Warning -> colors Warning Surface
  | Error -> colors ~attrs:[ Attr.bold ] Error Surface
;;
