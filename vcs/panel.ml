open! Core

module Id = struct
  type t = string [@@deriving sexp, equal, compare]

  let of_string = Fn.id
  let to_string = Fn.id
end

module Section_id = struct
  module T = struct
    type t = string [@@deriving sexp, equal, compare]
  end

  include T
  include Comparable.Make (T)

  let of_string = Fn.id
  let to_string = Fn.id
end

module Item = struct
  type 'a t =
    { key : string
    ; value : 'a
    }
  [@@deriving sexp_of]
end

module Section = struct
  type 'a t =
    { id : Section_id.t
    ; title : string
    ; items : 'a Item.t list
    }
  [@@deriving sexp_of]
end

type 'a t =
  { id : Id.t
  ; title : string
  ; sections : 'a Section.t list
  }
[@@deriving sexp_of]

let validate t =
  let duplicate list = List.find_a_dup list ~compare:String.compare in
  match duplicate (List.map t.sections ~f:(fun section -> section.Section.id)) with
  | Some section -> Or_error.error_s [%message "Duplicate section" (section : string)]
  | None ->
    Or_error.all_unit
      (List.map t.sections ~f:(fun section ->
         match duplicate (List.map section.items ~f:(fun item -> item.Item.key)) with
         | None -> Ok ()
         | Some key ->
           Or_error.error_s
             [%message "Duplicate key in section" ~section:(section.id : string) (key : string)]))
;;

module Position = struct
  type t =
    | Header of Section_id.t
    | Item of
        { section : Section_id.t
        ; key : string
        }
  [@@deriving sexp, equal, compare]

  let section = function
    | Header section | Item { section; _ } -> section
  ;;
end

let find_section t id =
  List.find t.sections ~f:(fun section -> Section_id.equal section.Section.id id)
;;

let find_item (section : _ Section.t) key =
  List.find section.items ~f:(fun item -> String.equal item.key key)
;;

let find t (position : Position.t) =
  match position with
  | Header _ -> None
  | Item { section; key } -> Option.bind (find_section t section) ~f:(fun s -> find_item s key)
;;

let mem t (position : Position.t) =
  match position with
  | Header section -> Option.is_some (find_section t section)
  | Item _ -> Option.is_some (find t position)
;;

type 'a panel = 'a t

module Cursor = struct
  type t =
    { selected : Position.t option
    ; folded : Section_id.Set.t
    }
  [@@deriving sexp, equal]

  let empty = { selected = None; folded = Section_id.Set.empty }

  let rows t (panel : _ panel) =
    List.concat_map panel.sections ~f:(fun section ->
      Position.Header section.id
      ::
      (if Set.mem t.folded section.id
       then []
       else
         List.map section.items ~f:(fun item ->
           Position.Item { section = section.id; key = item.key })))
  ;;

  let first_row t panel = List.hd (rows t panel)

  (* An item inside a folded section is shown as its header. *)
  let visible t (position : Position.t) =
    match position with
    | Item { section; _ } when Set.mem t.folded section -> Position.Header section
    | Header _ | Item _ -> position
  ;;

  (* The first of [candidates] (in order) that satisfies [present]. *)
  let first_present candidates ~present = List.find candidates ~f:present

  let section_gone t ~(previous : _ panel) ~(current : _ panel) section =
    let present (s : _ Section.t) = Option.is_some (find_section current s.id) in
    let before, after =
      match
        List.findi previous.sections ~f:(fun _ s -> Section_id.equal s.Section.id section)
      with
      | None -> [], []
      | Some (index, _) ->
        ( List.rev (List.take previous.sections index)
        , List.drop previous.sections (index + 1) )
    in
    match
      Option.first_some (first_present after ~present) (first_present before ~present)
    with
    | Some s -> Some (Position.Header s.id)
    | None -> first_row t current
  ;;

  let item_gone ~(previous : _ panel) ~(current_section : _ Section.t) key =
    let present (item : _ Item.t) = Option.is_some (find_item current_section item.key) in
    let selected item = Position.Item { section = current_section.id; key = item.Item.key } in
    match find_section previous current_section.id with
    | None -> Position.Header current_section.id
    | Some old_section ->
      (match
         List.findi old_section.items ~f:(fun _ item -> String.equal item.Item.key key)
       with
       | None -> Position.Header current_section.id
       | Some (index, _) ->
         let after = List.drop old_section.items (index + 1) in
         let before = List.rev (List.take old_section.items index) in
         (match
            Option.first_some
              (first_present after ~present)
              (first_present before ~present)
          with
          | Some item -> selected item
          | None -> Position.Header current_section.id))
  ;;

  let reconcile t ~previous ~current =
    let selected =
      match t.selected with
      | None -> first_row t current
      | Some position ->
        let section = Position.section position in
        (match find_section current section with
         | None -> section_gone t ~previous ~current section
         | Some current_section ->
           (match position with
            | Header _ -> Some position
            | Item { key; _ } ->
              if Option.is_some (find_item current_section key)
              then Some position
              else Some (item_gone ~previous ~current_section key)))
    in
    { t with selected = Option.map selected ~f:(visible t) }
  ;;

  let select t panel position =
    if mem panel position then { t with selected = Some (visible t position) } else t
  ;;

  let toggle_fold t panel section =
    match find_section panel section with
    | None -> t
    | Some _ ->
      if Set.mem t.folded section
      then { t with folded = Set.remove t.folded section }
      else (
        let t = { t with folded = Set.add t.folded section } in
        { t with selected = Option.map t.selected ~f:(visible t) })
  ;;
end
