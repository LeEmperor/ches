open! Core
open Bonsai_term

module Preset = struct
  type t =
    | Midnight
    | Crimson
    | Ember
    | Glacier
  [@@deriving sexp_of, equal, enumerate]
end

(* Legacy preset API; rendering receives its immutable theme explicitly. *)
let selected : Preset.t = Crimson

module Role = struct
  include Ches_theme.Theme.Role

  let color ?(preset = selected) t =
    let id = match preset with
      | Midnight -> "midnight" | Crimson -> "crimson"
      | Ember -> "ember" | Glacier -> "glacier"
    in
    let theme = Option.value_exn (Ches_theme.Theme.find id) in
    let r, g, b = Ches_theme.Theme.color theme t in
    Attr.Color.rgb ~r ~g ~b
  ;;
end

module Font = struct
  type t =
    | Bold
    | Italic
    | Underline
  [@@deriving sexp_of, equal, enumerate]

  let attr = function
    | Bold -> Attr.bold
    | Italic -> Attr.italic
    | Underline -> Attr.underline
  ;;

  let default : Ches_screen.Style.t -> t list = function
    | Title | Mode _ | Dirty | Pending | Error -> [ Bold ]
    | Backdrop
    | Document _
    | Gutter
    | Gutter_cursor_line
    | Border
    | Border_focused
    | Title_special
    | Status
    | Status_special
    | Hint
    | Info
    | Warning
    | Severity_hint
    | Stale
    | Smear
    | Diff_added
    | Diff_removed
    | Diff_hunk -> []
    | Diff_meta -> [ Bold ]
  ;;
end

let syntax_role : Ches_screen.Style.Syntax.t -> Role.t = function
  | Plain | Variable | Operator | Punctuation -> Foreground
  | Keyword -> Syntax_keyword
  | String -> Syntax_string
  | Number -> Syntax_number
  | Comment -> Syntax_comment
  | Type | Property -> Syntax_type
  | Function -> Syntax_function
  | Module -> Syntax_module
  | Constructor | Constant | Escape -> Syntax_constant
;;

let colors theme (style : Ches_screen.Style.t) =
  let color role =
    let r, g, b = Ches_theme.Theme.color theme role in
    Attr.Color.rgb ~r ~g ~b
  in
  let colors fg bg = [ Attr.fg (color fg); Attr.bg (color bg) ] in
  match style with
  | Backdrop -> colors Foreground Backdrop
  | Document { syntax; current_line; special; overlay } ->
    (match overlay with
     | Some Search_match -> colors Search_foreground Search_background
     | Some Search_current -> colors Search_current_foreground Search_current_background
     | Some Selection -> colors Selection_foreground Selection_background
     | Some Insert_cursor -> colors Background Block_cursor
     | Some Insert_point -> colors Background Block_copy
     | None ->
       colors
         (if special then Special else syntax_role syntax)
         (if current_line then Current_line else Background))
  | Gutter -> colors Muted Background
  | Gutter_cursor_line -> colors Foreground Current_line
  (* Frame cells (borders and the labels set into them) sit on the backdrop, so rounded
     corners read as round and the borders alone separate tiles across a gap. *)
  | Border -> colors Border Backdrop
  | Border_focused -> colors Normal_accent Backdrop
  | Title -> colors Foreground Backdrop
  | Title_special -> colors Special Backdrop
  | Status -> colors Foreground Surface
  | Status_special -> colors Special Surface
  | Hint -> colors Muted Backdrop
  | Mode Normal -> colors Background Normal_accent
  | Mode Insert -> colors Background Insert_accent
  | Mode (Visual _) -> colors Background Warning
  | Dirty -> colors Warning Surface
  | Pending -> colors Normal_accent Surface
  | Info -> colors Foreground Surface
  | Warning -> colors Warning Surface
  | Error -> colors Error Surface
  (* Quieter than Info but, unlike Stale, still in color: a hint is current, not dimmed. *)
  | Severity_hint -> colors Syntax_comment Surface
  | Stale -> colors Muted Surface
   | Smear -> [ Attr.fg (color Smear) ]
  (* Diff lines sit on the supporting views' surface, colored like Insert (added),
     errors (removed) and specials (hunk headers). *)
   | Diff_added -> colors Diff_added Surface
   | Diff_removed -> colors Diff_removed Surface
   | Diff_hunk -> colors Diff_hunk Surface
  | Diff_meta -> colors Foreground Surface
;;

let attrs ?(theme = Ches_theme.Theme.default) ?(font = Font.default) style =
  colors theme style @ List.map (font style) ~f:Font.attr
