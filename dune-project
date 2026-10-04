(lang dune 3.17)

(name ches)

(generate_opam_files true)

(license MIT)

(package
 (name ches)
 (synopsis "A small modal programmer's editor")
 (description
  "Ches is a prototype modal text editor with a UI-independent editing core and a Bonsai_term frontend.")
 (depends
  (ocaml
   (>= 5.2))
  (tree-sitter
   (= 0.1.0))
  core
  core_unix
  async
  bonsai
  bonsai_term
  ppx_jane))
