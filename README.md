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

Этапы 0 (каркас) и 1 (схема и API) закрыты. Работает связка «мигратор → схема →
REST `/api/v1`»: задачи создаются, читаются, переводятся, комментируются,
и всё это фиксируется в журнале активности.

| Проверка | Результат |
|---|---|
| `dune build --root .` | без ошибок (любое включённое предупреждение — ошибка) |
| `dune runtest --root .` | 62 теста OK — домен 17, идентичность 9, типы домена 8, репозитории 13, API 15 (живая БД) |
| `nix build .#doska` | успешно; checkPhase гоняет тесты без БД (в песочнице nix PostgreSQL нет) |
| `doska migrate` | применены `001_init.sql` и `002_task_ref_seq.sql`; повторный запуск — «нечего применять» |
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
├── db/         caqti: подключение, свой мигратор, репозитории (task, actor, project, evidence, activity)
├── api/        dream: REST /api/v1 (задачи, комментарии, доказательства, активность) + healthz
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

Объявлено 32 claim'а, у каждого — свой verifier, falsifier и **отрицательный
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

Покрытие области цели закрыто: `uncovered: 0 file(s)`. Все 32 claim'а выведены из
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
