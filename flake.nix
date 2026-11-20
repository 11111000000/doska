{
  description = "Doska — трекер обязательств для людей и агентов";

  # Пин совпадает с конфигурацией estate (AngaraConfig), чтобы пакеты
  # собирались теми же версиями, что и остальная система.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/b6018f87da91d19d0ab4cf979885689b469cdd41";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs:
        let
          o = pkgs.ocamlPackages;
          lib = pkgs.lib;

          direct = [
            o.yojson
            o.cmdliner
            o.lwt
            o.dream
            o.caqti
            o.caqti-lwt
            o.caqti-driver-postgresql
            o.alcotest
          ];

          # OCaml-пакеты тянут зависимости через propagatedBuildInputs.
          # findlib умеет искать только по OCAMLPATH, поэтому в dev-shell
          # путь собирается вручную (в сборках это делает findlib-hook).
          # OCaml-библиотеки в nixpkgs называются «ocaml<version>-<имя>-<версия>»
          # — так помечены и пакеты из набора ocamlPackages, и те, что nixpkgs
          # собирает сам (например, mirage-crypto-rng-lwt внутри dream).
          isOcaml = pkg: pkg ? name && lib.hasPrefix "ocaml" pkg.name;

          depsOf = pkg:
            lib.filter isOcaml
              ((pkg.propagatedBuildInputs or []) ++ (pkg.buildInputs or []));

          closure = seen: pkgs:
            lib.foldl'
              (acc: pkg:
                if lib.elem pkg seen then acc
                else
                  let seen' = seen ++ [ pkg ]; in
                  acc ++ [ pkg ] ++ closure seen' (depsOf pkg))
              [] pkgs;

          siteLib = pkg: "${pkg}/lib/ocaml/${o.ocaml.version}/site-lib";

          # Стандартная библиотека OCaml 5 лежит не в site-lib, а рядом с
          # компилятором: findlib должен видеть и её (seq, str, unix).
          ocamlPath = lib.concatStringsSep ":"
            ([ "${o.ocaml}/lib/ocaml" ]
            ++ lib.unique (lib.map siteLib (closure [] direct)));
        in
        {
          default = pkgs.mkShell {
            name = "doska-dev";
            # curl — HTTP-клиент импорта Mattermost (см. src/service/mattermost.ml).
            packages = [ o.ocaml o.dune_3 o.findlib pkgs.curl ] ++ direct;
            shellHook = ''
              export OCAMLPATH="${ocamlPath}"
              export PATH="${o.ocaml}/bin:${o.dune_3}/bin:$PATH"
              echo "doska dev shell" >&2
              echo "  dune:  $(which dune)" >&2
              echo "  build: dune build --root ." >&2
              echo "  test:  dune runtest --root ." >&2
            '';
          };
        });

      packages = forAllSystems (pkgs:
        let
          o = pkgs.ocamlPackages;
        in
        {
          doska = o.buildDunePackage {
            pname = "doska";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ o.dune_3 ];
            buildInputs = [
              o.yojson
              o.cmdliner
              o.lwt
              o.dream
              o.caqti
              o.caqti-lwt
              o.caqti-driver-postgresql
              # Тесты запускаются на этапе check, поэтому alcotest нужен и здесь.
              o.alcotest
              # Импорт Mattermost ходит по HTTP через curl (src/service/mattermost.ml).
              pkgs.curl
            ];

            # Проверка пакета идёт в герметичной песочнице nix, где PostgreSQL
            # нет. Тесты репозиториев и API требуют живую базу и без неё
            # честно падают — так и задумано: «тест прошёл» не должен означать
            # «тест не запустился». Поэтому в песочнице гоняются только тесты
            # без базы (домен, идентичность), а тесты с базой CI гоняет отдельно,
            # с сервисом postgres (шаг «Build and test»), и локально —
            # `dune runtest`.
            checkPhase = ''
              runHook preCheck
              dune build @install
              dune exec test/domain_test.exe
              dune exec test/identity_test.exe
              runHook postCheck
            '';

            doCheck = true;

            meta = {
              description = "Трекер обязательств для людей и агентов";
              mainProgram = "doska";
              platforms = [ "x86_64-linux" ];
              license = nixpkgs.lib.licenses.mit;
            };
          };
        });

      checks = forAllSystems (pkgs: {
        package = self.packages.${pkgs.system}.doska;
      });
    };
}
