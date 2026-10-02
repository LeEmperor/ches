open! Core
open Bonsai_term

module Role = struct
  type t =
    | Backdrop
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
      | Backdrop -> 0x0b, 0x0b, 0x0c
      | Background -> 0x11, 0x11, 0x13
      | Foreground -> 0xd0, 0xd0, 0xd0
      | Surface -> 0x1c, 0x1c, 0x1f
      | Muted -> 0x5a, 0x5a, 0x60
      | Border -> 0x3a, 0x3a, 0x40
      | Current_line -> 0x1d, 0x1d, 0x21
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
  | Backdrop -> colors Foreground Backdrop
  | Text -> colors Foreground Background
  | Text_cursor_line -> colors Foreground Current_line
  | Special -> colors Special Background
  | Special_cursor_line -> colors Special Current_line
  | Search_match -> colors Background Normal_accent
  | Search_match_current -> colors Background Insert_accent
  | Search_special_match -> colors Background Normal_accent
  | Search_special_match_current -> colors Background Insert_accent
  | Selection -> colors Background Warning
  | Selection_special -> colors Background Warning
  | Gutter -> colors Muted Background
  | Gutter_cursor_line -> colors Foreground Current_line
  | Border -> colors Border Background
  | Title -> colors ~attrs:[ Attr.bold ] Foreground Background
  | Title_special -> colors Special Background
  | Status -> colors Foreground Surface
  | Status_special -> colors Special Surface
  | Mode Normal -> colors ~attrs:[ Attr.bold ] Background Normal_accent
  | Mode Insert -> colors ~attrs:[ Attr.bold ] Background Insert_accent
  | Mode (Visual _) -> colors ~attrs:[ Attr.bold ] Background Warning
  | Dirty -> colors ~attrs:[ Attr.bold ] Warning Surface
  | Pending -> colors ~attrs:[ Attr.bold ] Normal_accent Surface
  | Info -> colors Foreground Surface
  | Warning -> colors Warning Surface
  | Error -> colors ~attrs:[ Attr.bold ] Error Surface
;;
