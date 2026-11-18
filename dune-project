(lang dune 3.0)
(name doska)
(generate_opam_files true)

(package
 (name doska)
 (synopsis "Трекер обязательств для людей и агентов")
 (description
  "Doska — система записи обязательств: кто кому что должен, в каком проекте, к какому сроку и в каком состоянии. Факты остаются у владельцев фактов (git, Teamboard, Mattermost), трекер хранит обязательства.")
 (depends
  (ocaml (>= "5.0"))))
