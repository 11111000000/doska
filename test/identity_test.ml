(** Разрешение имён: «Пётр», «petr», «@пётр» — один человек. *)

open Domain

let petr =
  Actor.make ~id:"u-petr" ~kind:Actor.Human ~handle:"petr" ~display_name:"Пётр" ()

let legist =
  Actor.make ~id:"a-legist" ~kind:Actor.Agent ~handle:"legist"
    ~display_name:"legist" ()

let store =
  {
    Identity.Resolve.actors = [ petr; legist ];
    aliases =
      [
        { Identity.Resolve.namespace = "mattermost"; value = "petrov"; actor_id = "u-petr" };
        { Identity.Resolve.namespace = "git"; value = "p.tr"; actor_id = "u-petr" };
      ];
  }

let resolve raw =
  Identity.Resolve.resolve store ~namespace:"mattermost" ~principal:legist ~raw

let resolved_actor = function
  | Identity.Resolve.Resolved { actor; _ } -> actor
  | Identity.Resolve.Placeholder { raw; _ } ->
      Alcotest.fail (Printf.sprintf "ожидался разрешённый актор, а получено «%s»" raw)

let () =
  Alcotest.run "идентичность"
    [
      ( "нормализация",
        [
          Alcotest.test_case "убирает пробелы и @, lowers регистр" `Quick (fun () ->
              Alcotest.(check string) "нормализовано" "петр"
                (Identity.Resolve.normalize "  @Пётр "));
          Alcotest.test_case "ё становится е" `Quick (fun () ->
              Alcotest.(check string) "нормализовано" "петр"
                (Identity.Resolve.normalize "ПЁтр"));
          Alcotest.test_case "схлопывает внутренние пробелы" `Quick (fun () ->
              Alcotest.(check string) "нормализовано" "петр петрович"
                (Identity.Resolve.normalize "  Петр   Петрович "));
        ] );
      ( "разрешение",
        [
          Alcotest.test_case "«я» — сам заявитель" `Quick (fun () ->
              Alcotest.(check string) "актор" "a-legist"
                (resolved_actor (resolve "я")).Actor.id);
          Alcotest.test_case "по логину" `Quick (fun () ->
              Alcotest.(check string) "актор" "u-petr"
                (resolved_actor (resolve "petr")).Actor.id);
          Alcotest.test_case "по отображаемому имени" `Quick (fun () ->
              Alcotest.(check string) "актор" "u-petr"
                (resolved_actor (resolve "Пётр")).Actor.id);
          Alcotest.test_case "по алиасу в текущем пространстве имён" `Quick (fun () ->
              Alcotest.(check string) "актор" "u-petr"
                (resolved_actor (resolve "petrov")).Actor.id);
          Alcotest.test_case "по алиасу из другого пространства" `Quick (fun () ->
              match resolve "p.tr" with
              | Identity.Resolve.Resolved { actor; new_alias } ->
                  Alcotest.(check string) "актор" "u-petr" actor.Actor.id;
                  Alcotest.(check (option string)) "новый алиас" (Some "p.tr")
                    new_alias
              | Identity.Resolve.Placeholder { raw; _ } ->
                  Alcotest.fail (Printf.sprintf "ожидался актор, получено «%s»" raw));
          Alcotest.test_case "неизвестное имя не теряется" `Quick (fun () ->
              match resolve "Незнакомец" with
              | Identity.Resolve.Placeholder { raw; normalized } ->
                  Alcotest.(check string) "исходное имя" "Незнакомец" raw;
                  Alcotest.(check string) "нормализованное" "незнакомец" normalized
              | Identity.Resolve.Resolved { actor; _ } ->
                  Alcotest.fail
                    (Printf.sprintf "ожидалась заглушка, получен актёр %s" actor.Actor.id));
        ] );
    ]
