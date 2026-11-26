# doska

Трекер обязательств для людей и агентов. Отвечает на один вопрос: **кто кому
что должен, в каком проекте, к какому сроку, в каком состоянии** — и даёт всем
сторонам (людям и агентам) один и тот же ответ.

Написан на OCaml. Фронтенд — веб-компоненты на чистом JavaScript + D3.js (этап 5).

## Границы

| Система | Что ей принадлежит | Чего здесь не будет |
|---|---|---|
| **git** | факты: ветки, коммиты, merge, diff, автор | трекер **никогда** не пересчитывает git-факты и не дублирует их |
| **Teamboard** | измерение по репозиториям, отчёт инвестору, инициативы | трекер не заменяет доску; он ссылается на её карточки |
| **Mattermost** | разговор: треды, реакции, ответы людей | трекер не хранит переписку |
| **doska** | **обязательства**: кто кому что должен, сроки, статус, доказательства | — |

> **Факт пересчитывается владельцем факта. Суждение живёт в трекере.
> Наблюдение — ссылка, а не копия.**

Ветка, PR и коммит — это `evidence` внутри задачи, а не отдельная единица
работы. Задача — это обязательство.

## Состояние

Этапы 0 и 1 закрыты, от этапа 2 взяты семь срезов: идентичность, сервисный
слой, главный запрос, заявка и отпуск, иерархия и связи, сводка и вопрос при
`needs_input`. Работает связка «мигратор → схема → REST `/api/v1`»: задачи
создаются, читаются, переводятся, комментируются, заявляются и отпускаются, агент действует по bearer-токену (учётки — первый срез этапа 4), задачи приходят из Mattermost командой /task (вебхук с кнопками и DM), панель doska есть в Paseo,
делятся на части и связываются между собой, `/overview` отвечает одним запросом
«где застряло и кто перегружен», а задача в `needs_input` ждёт ответа
конкретного человека — и всё это фиксируется в журнале активности.

| Проверка | Результат |
|---|---|
| `dune build --root .` | без ошибок (любое включённое предупреждение — ошибка) |
| `dune runtest --root .` | 199 тестов OK — домен 26, идентичность 9, типы домена 9, репозитории 13, идентичность на базе 10, сервисный слой 28, учётки агентов 4, сводка 10, вопрос при `needs_input` 15, API 63 (живая БД) |
| `nix build .#doska` | успешно; checkPhase гоняет тесты без БД (в песочнице nix PostgreSQL нет) |
| `doska migrate` | применены `001_init.sql` … `006_task_question.sql`; повторный запуск — «нечего применять» |
| `doska health` | `ok` |
| `doska serve` → `/healthz` | 200 `{"status":"ok"}` |

Живая проверка API (временная база, сервер на порту):

```sh
doska migrate --migrations-dir migrations
doska serve --port 8500 &
curl -s -H 'X-Doska-Actor: petr' http://[::1]:8500/api/v1/tasks
```

Ответ на `POST /api/v1/tasks` содержит `ref` вида `DSK-1`; повторное создание с
той же парой `(source, source_ref)` возвращает ту же задачу и не плодит дубль.

Этапы 2–10 — в `docs/design/doska-architecture-2026-11-16.md`. Как вести
разработку, где мы находимся и что делать дальше — в
[docs/development-guide.md](docs/development-guide.md).

## Сборка и запуск

Нужен Nix с флэйками.

```sh
nix develop              # dev-оболочка: ocaml 5.3, dune 3.20, зависимости
dune build --root .
dune runtest --root .
```

Сборка пакета:

```sh
nix build .#doska --no-link
nix path-info .#doska    # путь к артефакту в store
```

Применение миграций и запуск:

```sh
export DOSKA_DATABASE_URL="postgresql:///doska"

doska migrate --migrations-dir migrations
doska health
doska serve --port 8500
```

`doska --help` печатает список команд: `serve`, `migrate`, `health`, `version`.

### Переменные окружения

| Переменная | Смысл |
|---|---|
| `DOSKA_DATABASE_URL` | URI PostgreSQL: значение по умолчанию для `--db-url`, явный флаг перекрывает переменную. Секреты в код не прошиты |

### Требования к базе

PostgreSQL 17 с расширениями `citext` (регистронезависимые имена) и `pg_trgm`
(поиск по похожим именам). Расширения создаёт миграция.

## Структура

```
src/
├── domain/     чистый домен: статусы, правила, задачи, акторы, проекты — ни БД, ни HTTP
├── identity/   нормализация имён и resolve алиасов в актора
├── db/         caqti: подключение, свой мигратор, репозитории (task, actor, project, evidence, activity, link, overview)
├── api/        dream: REST /api/v1 (задачи, комментарии, доказательства, активность, сводка) + healthz
├── version/    имя и версия
└── bin/        cmdliner: doska serve | migrate | health | version
migrations/     идемпотентные SQL-файлы, применяются по имени
test/           alcotest: домен, идентичность, репозитории, API + shell-проверки миграций и control'ов
docs/           архитектура и разведка по estate
```

Каталоги `domain`, `identity`, `db`, `api`, `version` — **отдельные
библиотеки dune**, а не подкаталоги одной. Это не стилистика: dune не включает
модули из подкаталогов в библиотеку автоматически, а раздельные библиотеки
превращают правило «домен не знает про БД» в зависимость, которую dune не даст
нарушить молча.

## Слой доказательств (math-coding)

Каждое обязательство из принятой архитектуры связано с проверяемым
доказательством. Метод — [math-coding](https://github.com/11111000000/math-coding)
v5: он не заменяет тесты и CI, а строит поверх них карту «что подтверждено,
чем и насколько независимо».

```sh
nix develop -c bash -c 'mathc --root . run'
```

Объявлено 93 claim'а, у каждого — свой verifier, falsifier и **отрицательный
control**: control меняет предмет так, что verifier обязан упасть. Если
verifier падает и без control'а, он не проверяет ничего — метод это
показывает.

| Claim | Что утверждает | Verifier | Отрицательный control |
|---|---|---|---|
| `r1-agent-acceptance` | Агент не закрывает задачу сам: `in_review → done` доступен агенту только при `autonomy = auto` (D1) | `dune exec --root . test/domain_test.exe` | `r1_autonomy.sh` |
| `identity-resolution` | «Пётр» и его варианты — один актор; нераспознанное имя не теряется, а возвращается заглушкой (§5.2) | `dune exec --root . test/identity_test.exe` | `identity_yo.sh` |
| `migration-idempotent` | Повторное применение миграции не создаёт дублей таблиц и типов | `sh test/check_migration.sh idempotent` | `migration_not_idempotent.sh` |
| `migration-immutable` | Уже применённый файл менять нельзя: мигратор сверяет контрольную сумму и отказывается работать | `sh test/check_migration.sh immutable` | `migration_no_checksum.sh` |
| `api-transition-r1` | Запрет правила домена через API — это 403 с деталями перехода, а не 500 (§6.1, D1) | `dune exec --root . test/api_test.exe` | `api_forbidden_is_500.sh` |
| `api-list-pagination` | Список задач отдаётся постранично: фильтры отбирают нужное, курсор приходит, пока список не кончился | `dune exec --root . test/api_test.exe` | `api_pagination_broken.sh` |
| `api-idempotent-create` | Повторное создание с той же парой `(source, source_ref)` возвращает ту же задачу и не плодит дубль | `dune exec --root . test/api_test.exe` | `api_create_not_idempotent.sh` |
| `repo-status-persistence` | Смена статуса сохраняется, а `version` защищает задачу от гонки | `dune exec --root . test/repo_test.exe` | `repo_status_not_saved.sh` |
| `api-error-contract` | Ошибки API различаются по классу: 400, 401, 403, 404, 409; тело ошибки — один и тот же объект | `dune exec --root . test/api_test.exe` | `api_error_status_is_400.sh` |
| `api-actor-required` | Без заголовка `X-Doska-Actor` — 401; неизвестный логин — тоже 401, а не анонимный доступ | `dune exec --root . test/api_test.exe` | `api_actor_error_is_403.sh` |
| `api-view-links` | Карточка задачи отдаёт читаемые человеком ссылки: исполнитель — именем и идентификатором | `dune exec --root . test/api_test.exe` | `api_view_assignee_is_id.sh` |
| `api-invalid-body` | Битое тело запроса — 400, а не 500: разбор тела не роняет обработчик | `dune exec --root . test/api_test.exe` | `api_invalid_body_is_500.sh` |
| `db-value-escaping` | Значения в SQL экранируются: кавычка в тексте не ломает запрос, а значение доезжает целым | `dune exec --root . test/repo_test.exe` | `db_quote_not_escaped.sh` |
| `db-transaction-atomicity` | Транзакция цела: сбой внутри неё не оставляет изменений — запись в журнал идёт вместе с правкой | `dune exec --root . test/repo_test.exe` | `db_transaction_commits_on_error.sh` |
| `db-activity-filters` | Журнал выбирается по фильтрам: выборка по задаче не содержит событий другой задачи | `dune exec --root . test/repo_test.exe` | `db_activity_filter_ignored.sh` |
| `db-actor-lookup` | Актёр находится по своему логину, а не по отображаемому имени | `dune exec --root . test/repo_test.exe` | `db_actor_by_display_name.sh` |
| `db-project-lookup` | Проект находится по своему ключу, а не по названию | `dune exec --root . test/repo_test.exe` | `db_project_by_name.sh` |
| `db-evidence-ownership` | Доказательство принадлежит своей задаче: в списке чужой задачи его нет | `dune exec --root . test/repo_test.exe` | `db_evidence_without_task_filter.sh` |
| `domain-closed-types` | Домен — замкнутые типы: `to_string` и `of_string` возвращают друг друга, а чужое имя не принимается | `dune exec --root . test/domain_types_test.exe` | `domain_status_renamed.sh` |
| `identity-alias-namespace` | Пространства имён разделяют алиасы: чужой алиас предлагается как новый, а не срабатывает | `dune exec --root . test/identity_test.exe` | `identity_alias_ignores_namespace.sh` |
| `cli-health-and-version` | CLI объявляет версию и честно проверяет живость базы: без базы health падает, а не печатает «ok» | `sh test/check_cli.sh` | `cli_health_ping_broken.sh` |
| `test-harness-needs-db` | Обвязка тестов не молчит: тест, которому нужна база, без базы падает, а не проходит мимо | `sh test/check_tests_need_db.sh` | `test_harness_ignores_db_url.sh` |
| `controls-prove-verifiers` | Каждый control меняет свой предмет ровно в одном месте, применим к текущим исходникам и объявлен control'ом ровно одного claim'а: claim без control'а — не claim | `sh test/check_controls.sh` | `control_breaks_two_places.sh` |
| `migration-actor-source` | Один внешний объект — одна строка актёра: пара `(source, source_ref)` уникальна, миграция `003` идемпотентна (§10.2) | `sh test/check_actor_source.sh` | `actor_source_not_unique.sh` |
| `db-actor-source-lookup` | Актёр находится по паре `(source, source_ref)`: актёр одного источника не находится по ключу другого (§10.2) | `dune exec --root . test/identity_db_test.exe` | `db_actor_source_ignored.sh` |
| `db-alias-repository` | Алиасы живут в пространстве имён, имя регистронезависимо, повторная запись не создаёт второй строки (§5.2) | `dune exec --root . test/identity_db_test.exe` | `db_alias_duplicate.sh` |
| `identity-placeholder-write` | Нераспознанное имя не теряется: резолвер создаёт заглушку `unresolved = true` с алиасом, повторный резолв находит ту же заглушку (§3.1) | `dune exec --root . test/identity_db_test.exe` | `identity_placeholder_not_flagged.sh` |
| `identity-resolve-alias-write` | Алиас, найденный в чужом пространстве имён, копируется в своё (§5.2, шаг 4) | `dune exec --root . test/identity_db_test.exe` | `identity_resolve_no_alias_write.sh` |
| `api-actors-resolve` | `POST /api/v1/actors/resolve` отвечает актёром по имени, неизвестное имя даёт заглушку, пустое имя — 400 (§6.1) | `dune exec --root . test/api_test.exe` | `api_actors_resolve_missing.sh` |
| `identity-import-kind` | Импорт различает человека и агента: агент — непустая должность или служебный адрес `@localhost` (§5.3) | `dune exec --root . test/identity_db_test.exe` | `identity_import_kind_by_position.sh` |
| `identity-import-idempotent` | Повторный импорт Mattermost обновляет те же строки, а не создаёт новые (§10.2) | `dune exec --root . test/identity_db_test.exe` | `identity_import_duplicate.sh` |
| `identity-import-aliases` | Импорт заводит алиасы по логину, полному имени и имени без фамилии (§5.3) | `dune exec --root . test/identity_db_test.exe` | `identity_import_no_first_name.sh` |
| `service-layer-rules` | Правила и транзакции задач живут в сервисном слое, а не в HTTP-обработчике (D5): REST, MCP и CLI — адаптеры над одним use case (§6.0, D5) | `sh test/check_service_layer.sh` | `service_rules_in_api.sh` |
| `service-journal-interface` | Журнал помнит интерфейс, через который пришло действие: вызов агента из paseo не выглядит как человеческий REST (§11, D5) | `dune exec --root . test/service_task_test.exe` | `service_journal_interface_constant.sh` |
| `service-assign-rule` | Правило назначения доменное: агент не может назначить задачу другому, отказ приходит как запрет правила (§4.2, D5) | `dune exec --root . test/service_task_test.exe` | `service_assign_rule_allowed.sh` |
| `service-failure-types` | Отказ use case — данные: закрытый тип ошибок сервиса, ошибка хранилища не выглядит как запрет правила (§6.0, D5) | `dune exec --root . test/service_task_test.exe` | `service_storage_is_forbidden.sh` |
| `service-patch-journal` | Правка задачи пишет в журнал `updated` со сводкой изменённых полей, а не выдаёт себя за смену статуса (§3.6, D5) | `dune exec --root . test/service_task_test.exe` | `service_patch_journal_is_status_change.sh` |
| `service-interface-set` | Набор интерфейсов один и тот же в домене и в базе: закрытый тип, а не произвольная строка (D5) | `sh test/check_service_layer.sh` | `service_interface_set_mismatch.sh` |
| `api-mine-assignee-scope` | «Мои задачи» — это задачи исполнителя из заголовка актора: чужая задача в выборку не попадает (§6.1) | `dune exec --root . test/api_test.exe` | `api_mine_assignee_ignored.sh` |
| `api-mine-order` | Главный запрос отсортирован по срочности: просроченная задача раньше задачи со сроком позже (§6.1) | `dune exec --root . test/api_test.exe` | `api_mine_order_swapped.sh` |
| `api-mine-open-only` | В главный запрос попадают только открытые задачи: завершённые и отменённые — нет (§6.1) | `dune exec --root . test/api_test.exe` | `api_mine_closed_included.sh` |
| `api-mine-pagination` | Пагинация главного запроса не теряет и не повторяет строку: курсор — строго следующая по порядку (§6.1) | `dune exec --root . test/api_test.exe` | `api_mine_cursor_inclusive.sh` |
| `api-mine-route` | `/tasks/mine` — главный запрос, а не чтение задачи по референсу: статический маршрут стоит раньше параметризованного (§6.1) | `dune exec --root . test/api_test.exe` | `api_mine_route_after_ref.sh` |
| `api-claim-assignee-scope` | Заявку на чужую задачу агент получить не может: свободную берёт любой агент, назначенную — только её исполнитель (§4.1, §6.1) | `dune exec --root . test/api_test.exe` | `api_claim_steal_assigned.sh` |
| `api-claim-assignee` | Заявка на свободную задачу назначает претендента исполнителем, а назначение не отменяет (§6.1) | `dune exec --root . test/service_task_test.exe` | `api_claim_assignee_replaced.sh` |
| `api-claim-source-status` | Заявка допустима только из статуса `todo`: из другого статуса — 409, а не 400 и не 200 (§6.1) | `dune exec --root . test/service_task_test.exe` | `api_claim_source_status.sh` |
| `api-release-owner` | Отпустить задачу может её исполнитель-агент или любой человек; посторонний агент — 403 (§4.1, §6.1) | `dune exec --root . test/api_test.exe` | `api_release_any_agent.sh` |
| `api-release-pool` | Отпуск возвращает задачу в пул: статус становится `todo`, исполнитель снят (§6.1) | `dune exec --root . test/service_task_test.exe` | `api_release_keeps_assignee.sh` |
| `api-claim-journal` | Заявка оставляет в журнале действие `claimed` — по нему видно, кто задачу взял (§6.1) | `dune exec --root . test/service_task_test.exe` | `api_claim_journal_swapped.sh` |
| `api-release-journal` | Отпуск оставляет в журнале действие `released` — по нему видно, кто задачу вернул в пул (§6.1) | `dune exec --root . test/service_task_test.exe` | `api_release_journal_swapped.sh` |
| `domain-link-direction` | Направление блокировки однозначно: `blocks` — «from блокирует to», `blocked_by` — обратное (§3.5, §6.1) | `dune exec --root . test/domain_test.exe` | `domain_link_direction.sh` |
| `domain-parent-closed` | Родителя нельзя перевести в `done`, пока у него открытые дети: правило живёт в домене (§6.1) | `dune exec --root . test/domain_test.exe` | `domain_parent_closed.sh` |
| `api-link-kind` | Неизвестный вид связи — 400, а не запись связи с чужим видом (§6.1) | `dune exec --root . test/api_test.exe` | `api_link_unknown_kind.sh` |
| `api-link-self` | Связь задачи с собой отклоняется (§6.1) | `dune exec --root . test/api_test.exe` | `api_link_self.sh` |
| `api-link-duplicate` | Повторная связь отклоняется, в том числе записанная с другой стороны (§6.1) | `dune exec --root . test/api_test.exe` | `api_link_duplicate.sh` |
| `api-link-cycle` | Кольцо блокировок не записывается: цепочка блокировок остаётся без петель (§6.1) | `dune exec --root . test/service_task_test.exe` | `api_link_cycle.sh` |
| `api-link-unlink-scope` | Связь снимается только из своей задачи: чужая связь оттуда не снимается (§6.1) | `dune exec --root . test/api_test.exe` | `api_link_unlink_scope.sh` |
| `api-parent-cycle` | Родителем нельзя назначить собственного потомка: дерево не замыкается в кольцо (§6.1) | `dune exec --root . test/api_test.exe` | `api_parent_cycle.sh` |
| `api-parent-version` | Версия обязательна при смене родителя: смена меняет задачу и ломает её блокировку (§6.1) | `dune exec --root . test/api_test.exe` | `api_parent_version.sh` |
| `api-parent-create` | Родитель, указанный при создании задачи, записывается в дерево (§6.1) | `dune exec --root . test/api_test.exe` | `api_parent_create.sh` |
| `overview-open-tasks` | Открытая задача считается открытой по статусу: закрытые и удалённые в сводку не попадают (§6.1) | `dune exec --root . test/service_overview_test.exe` | `ov_open_condition.sh` |
| `overview-stuck-rule` | Застой — это начатые статусы (`in_progress`, `blocked`, `in_review`): задача, ждущая ответа человека, в застой не попадает (R2, §4.2, §6.1) | `dune exec --root . test/service_overview_test.exe` | `ov_stuck_statuses.sh` |
| `overview-project-load` | Нагрузка по проектам — только проекты с открытыми задачами (§6.1) | `dune exec --root . test/service_overview_test.exe` | `ov_project_having.sh` |
| `overview-wip-order` | Нагрузка по людям отсортирована по убыванию числа открытых задач, при равенстве — по логину (§6.1) | `dune exec --root . test/service_overview_test.exe` | `ov_wip_order.sh` |
| `overview-stuck-threshold` | Порог застоя задан параметром `stuck_days`, и применённый порог возвращается в ответе (§6.1) | `dune exec --root . test/service_overview_test.exe` | `ov_stuck_days_threshold.sh` |
| `overview-limit` | Предел длины списков задан параметром `limit`, и применённый предел возвращается в ответе (§6.1) | `dune exec --root . test/service_overview_test.exe` | `ov_limit.sh` |
| `overview-parameter-range` | Значения вне допустимого диапазона отклоняются: `stuck_days` меньше суток и `limit` вне 1…200 — 400 (§6.1) | `dune exec --root . test/service_overview_test.exe` | `ov_limit_range.sh` |
| `overview-api-shape` | `GET /api/v1/overview` отдаёт сводку в объявленной форме: счётчики, нагрузка по людям и проектам, застрявшие, ждущие ответа (§6.1) | `dune exec --root . test/api_test.exe` | `ov_response_shape.sh` |
| `overview-api-parameters` | Неразобранный параметр сводки — ошибка запроса (400), а не молчаливая замена (§6.1) | `dune exec --root . test/api_test.exe` | `ov_unparsable_parameter.sh` |
| `needs-input-question-required` | Вход в `needs_input` требует текст вопроса: `reason` в переходе — это вопрос (§6.1) | `dune exec --root . test/domain_test.exe` | `q_question_required.sh` |
| `needs-input-addressee-required` | Вход в `needs_input` требует адресата: вопрос без адресата (явного или выведенного) отклоняется (§6.1) | `dune exec --root . test/domain_test.exe` | `q_addressee_required.sh` |
| `needs-input-answer-required` | Выход из `needs_input` требует ответа: `reason` ответ не заменяет (§6.1) | `dune exec --root . test/domain_test.exe` | `q_answer_required.sh` |
| `needs-input-answerer` | Отвечает на вопрос только человек — адресат, заявитель, руководитель или администратор (§4.1) | `dune exec --root . test/domain_test.exe` | `q_answerer_only_human.sh` |
| `needs-input-question-stored` | Текст вопроса и адресат сохраняются в задаче и остаются в карточке после перехода в `needs_input` (§6.1) | `dune exec --root . test/task_question_test.exe` | `q_question_stored.sh` |
| `needs-input-addressee-resolved` | Адресат вопроса — человек: он задан явно или выведен по цепочке (заявитель → руководитель исполнителя → руководитель заявителя → администратор) (§6.1) | `dune exec --root . test/task_question_test.exe` | `q_addressee_resolved.sh` |
| `needs-input-history` | Вопрос и ответ переживают смену статуса, а новый вопрос обнуляет прежний ответ (§6.1) | `dune exec --root . test/task_question_test.exe` | `q_previous_answer_cleared.sh` |
| `needs-input-notification` | Постановка вопроса кладёт в outbox уведомление адресату: канал `mattermost_dm`, вид `needs_input`, состояние `pending` (§3.8) | `dune exec --root . test/task_question_test.exe` | `q_notification_enqueued.sh` |
| `api-ask-answer-contract` | REST-контракт перехода с вопросом: `reason` — текст `question`, `answer` обязателен на выходе, карточка отдаёт `question`, `asked_to_id`, `asked_to`, `answer`, `answered_at` (§6.1) | `dune exec --root . test/task_question_test.exe` | `q_api_asked_to.sh` |
| `needs-input-migration` | Миграция вопроса (006) идемпотентна: пять колонок добавляются через `IF NOT EXISTS`, значения журнала `questioned` и `answered` — тоже, поэтому повторное развёртывание не падает (§9.2, §4.2) | `sh test/check_task_question_migration.sh` | `q_migration_not_idempotent.sh` |
| `task-upsert-from-source` | Повторный импорт с той же парой (source, source_ref) обновляет контентные поля версионированной правкой с журналом и не плодит дубль; статус и исполнитель — только машиной переходов (§10.2) | `dune exec --root . test/service_task_test.exe` | `upsert_skips_update.sh` |

Покрытие области цели закрыто: `uncovered: 0 file(s)`. Все 93 claim'а выведены из
`docs/design/doska-architecture-2026-11-16.md` как источника: правка
архитектуры помечает их как `outdated` и требует пересмотра человеком.

Отрицательный control не имеет права ломать сборку: он ломает **поведение**,
иначе падение verifier'а ничего не доказывает. Это проверяет сам
`test/check_controls.sh` — каждый control обязан менять ровно один файл и
оставаться применимым к текущим исходникам.

Зелёный verdict относится **только** к объявленным claim'ам. Файлы вне
покрытия `mathc` печатает списком `uncovered` — их надо сообщать вместе с
вердиктом, а не по отдельности.

Проверки, которым нужна база, берут её из `DOSKA_DATABASE_URL` (по умолчанию —
локальный сокет `postgresql:///doska`); ни один verifier не зашивает способ
подключения. Проверка «тест падает без базы» обязана спрашивать базу у того же
сервера, что и рабочая база, — только другое имя. Иначе в CI, где postgres
доступен по TCP, она падала бы по любой неработающей базе и не доказывала бы
ничего.

Правила работы с методом для агентов — в [AGENTS.md](AGENTS.md), раздел
«Слой доказательств».

## Документы

- `docs/design/doska-architecture-2026-11-16.md` — архитектура: границы,
  принципы, полный DDL, машина состояний, идентичность, интерфейсы, этапы,
  риски, решения D1–D3. Статус: принято.
- `docs/development-guide.md` — ведение проекта: где мы находимся, как поднять
  с нуля, как работать со слоем доказательств, что делать на этапе 2, какие
  вопросы открыты. Статус: живой документ.
- `docs/decision-log.md` — журнал решений: что, кем и почему решено, что
  осталось открытым. Статус: append-only.
- `docs/research/estate-research-2026-11-16.md` — разведка по estate
  (Teamboard, AngaraChat, Mattermost, pm-global, `subroutine`, `agent-kanban`):
  что переиспользуем, что нет, что дублируем. Статус: заменено.

## Лицензия

MIT — см. [LICENSE](LICENSE).
