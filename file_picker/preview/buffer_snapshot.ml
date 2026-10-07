open! Core
let lookup session ~path =
  Option.bind (Ches_app.Session.find_resource session path) ~f:(fun (_, controller) ->
    match Ches_app.Controller.kind controller with
    | Directory -> None
    | File ->
      let editor = Ches_app.Controller.editor controller in
      Some (Model.of_buffer ~revision:(Ches_core.Editor.revision editor)
        (Ches_core.Editor.text editor)))
;;
