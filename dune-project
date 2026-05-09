(lang dune 3.16)

(name dovetail)

(generate_opam_files true)

(package
 (name dovetail)
 (synopsis "A relational database built on top of LMDB")
 (description
  "Dovetail is a learning-first relational database in OCaml. It implements relational algebra and is queryable via two languages: a pipeline-style RA language and SQL, both compiling to a shared algebraic IR.")
 (depends
  (ocaml
   (>= 5.2))
  (dune
   (>= 3.16))
  lmdb
  angstrom
  (alcotest :with-test)))
