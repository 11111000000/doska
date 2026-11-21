---
title: Архитектура собственного трекера задач — проект с нуля
date: 2026-11-16
status: принято (решения D1–D3 зафиксированы в §13)
code_name: doska
---

# Архитектура трекера задач (собственный, с нуля)

> Имя проекта — **`doska`** (решение владельца 18.11.2026). Оно не прошито в
> схему БД: меняется в коде, URL и названии сервиса. Референс задачи в БД
> формируется как `DSK-<номер>`.

---

## 1. Что это за система и чего она не делает

**Это система записи обязательств.** Отвечает на вопрос: **кто кому что должен,
в каком проекте, к какому сроку, в каком состоянии** — и даёт всем сторонам
(людям и агентам) один и тот же ответ.

### Границы (жёсткие)

| Система | Что ей принадлежит | Чего в трекере не будет |
|---|---|---|
| **git** | факты: ветки, коммиты, merge, diff, автор | трекер **никогда** не пересчитывает git-факты и не дублирует их |
| **Teamboard** | измерение по репозиториям, отчёт инвестору, инициативы | трекер не заменяет доску; он ссылается на её карточки |
| **Mattermost** | разговор: треды, реакции, ответы людей | трекер не хранит переписку |
| **Трекер** | **обязательства**: кто кому что должен, сроки, статус, доказательства | — |

Правило, из которого выводится всё остальное:

> **Факт пересчитывается владельцем факта. Суждение живёт в трекере.
> Наблюдение — ссылка, а не копия.**

Это прямо наследует принцип, который уже доказал работоспособность в этом
estate (`Teamboard/AGENTS.md:16-107`): *«факт пересчитывается, суждение
пересматривается»*. В трекере к этому добавляется третий слой — **ссылка на
факт**, потому что git-факт нельзя ни скопировать в трекер (он протухнет), ни
пересчитывать (это работа git).

### Явные не-цели

- **Не заменять git-протокол координации агентов.** Это была причина провала
  `agent-kanban` (ADR `AngaraConfig/KB/30_decisions/agent-kanban-disabled-2026-10-16.md:23-27`):
  агенты уже работают в worktree-ветках с auto-commit/auto-merge. Трекер живёт
  **над** этим, а не вместо.
- **Не быть ещё одним местом, куда надо сходить.** Каждая функция трекера
  доступна из места, где человек или агент уже находится: из чата, из
  календаря, из терминала, из Paseo.
- **Не быть общим чатом задач.** Обсуждение — комментарии внутри задачи.
- **Не тянуть больше, чем нужно.** Postgres на том же инстансе, один процесс
  API + один воркер outbox. Никакого Redis, никакого отдельного брокера.

---

## 2. Принципы

Каждый принцип — из наблюдаемого дефекта нынешнего состояния.

**П1. Назначение — это ссылка на актора, а не строка.**
Сейчас `owner` в Teamboard — свободный текст: `Пётр` (35 карточек), `az` (29),
`human:operator` (19), `legist` (14 — это агент!), `upstream getpaseo/paseo` (4),
пусто (85). Ответ на вопрос «задачи Пётра» получить нельзя.
→ `task.assignee_id` — внешний ключ. Свободного текста в поле назначения нет
физически.

**П2. Люди и агенты — одна сущность с разным поведением, а не две сущности.**
Сегодня агент `legist` стоит рядом с человеком `Пётр` в одном поле.
→ Единая таблица `actor` с признаком `kind` и связью `supervisor_id`: агент
отвечает перед человеком. Это даёт эскалацию, приёмку и отчётность.

**П3. Агент не закрывает свою же задачу.**
Это перенос «эпистемической честности» (`Teamboard/AGENTS.md:284`) из отчётов
в рабочий процесс: агент доходит до `in_review` и **просит приёмки**; закрывает
заявитель или руководитель.
→ Машина состояний с правилами переходов, проверяемыми на сервере.

**П4. Каждое изменение оставляет след.**
→ Append-only журнал `activity` с указанием **интерфейса** (`api | mcp | cli |
web | mattermost | paseo | import | system`). Это и аудит, и инструмент
диагностики: «кто и откуда плодит задачи» — один запрос.

**П5. Git — источник ссылок, а не источник состояния.**
→ Таблица `evidence`: sha, ветка, PR, файл, URL. Трекер их не проверяет и не
пересчитывает — он помнит, что было приложено.

**П6. У агента есть ровно одна точка входа.**
Три точки конфигурации убили `agent-kanban` (ADR, п. 3). Здесь: один
`credentials`-реестр в трекере + один MCP-конфиг + один `AGENTS.md` бота.
→ Меньше — нельзя.

**П7. Человек получает пользу в первый же день, ничего не меняя в привычках.**
→ Импорт существующих данных (доска, план дня) + ICS-календарь + команды в чате.
Трекер, в который надо сначала «перенести всё», не будет adopted.

**П8. Нет отдельного трекера для трекера.**
Каждая сущность живёт в одном месте. Teamboard и трекер не делят сущности
«задача» — они ссылаются друг на друга.

---

## 3. Модель данных

PostgreSQL 17 (на этом хосте уже работает: 17.10, доступны `citext`, `ltree`,
`pg_trgm`, `btree_gin`). Почему Postgres, а не SQLite: конкурентные записи
(боты и люди одновременно), внешние ключи как гарантия целостности, `jsonb` для
метаданных, `LISTEN/NOTIFY` для живой доски, RLS на будущее. SQLite-подход
`subroutine` для 12 пользователей и 0 задач — рабочий, но не переживёт
«50 проектов × 12 людей × 10 агентов».

### 3.1. Акторы

```sql
CREATE TYPE actor_kind   AS ENUM ('human','agent','service','placeholder');
CREATE TYPE actor_status AS ENUM ('active','inactive','archived');

CREATE TABLE actor (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind          actor_kind   NOT NULL,
    handle        citext       NOT NULL,          -- канонический логин: petr, comrade
    display_name  text         NOT NULL,          -- Пётр, @доска
    email         citext       UNIQUE,
    supervisor_id uuid         REFERENCES actor(id) ON DELETE SET NULL,
    status        actor_status NOT NULL DEFAULT 'active',
    unresolved    boolean      NOT NULL DEFAULT false,  -- placeholder: не подтверждён
    meta          jsonb        NOT NULL DEFAULT '{}',
    source        text,                     -- откуда актёр: mattermost | manual | ...
    source_ref    text,                     -- ключ объекта в источнике: id пользователя
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT actor_handle_uniq UNIQUE (handle)
);
CREATE INDEX actor_supervisor_idx ON actor(supervisor_id);
CREATE INDEX actor_display_idx    ON actor (lower(display_name));

-- Один внешний объект — одна строка. Индекс частичный: у актёров, созданных
-- вручную, источника нет, и в уникальность они не попадают.
CREATE UNIQUE INDEX actor_source_ref_uniq ON actor (source, source_ref)
    WHERE source IS NOT NULL AND source_ref IS NOT NULL;

-- Алиасы: один и тот же человек называется по-разному в разных системах.
CREATE TABLE actor_alias (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id   uuid NOT NULL REFERENCES actor(id) ON DELETE CASCADE,
    alias      citext NOT NULL,
    namespace  text NOT NULL,   -- mattermost | teamboard | git | email | manual
    source_ref text,            -- откуда: annotations.json#/annotations/*/owner
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (namespace, alias)
);
CREATE INDEX actor_alias_alias_idx ON actor_alias(alias);
```

**`unresolved = true`** — ключевая деталь. При импорте старых данных
`human:operator` и `upstream getpaseo/paseo` не выбрасываются и не подставляются
«как есть»: создаётся `actor(kind='placeholder', unresolved=true)`, чтобы данные
не потерялись и чтобы человек потом мог привязать placeholder к настоящему
человеку одной операцией.

**`supervisor_id`** — «кому отвечает агент». Даёт:
эскалацию (`needs_input` → уведомить руководителя), приёмку (руководитель может
закрыть задачу агента), отчётность (круглые суммы «чьи задачи зависли»).

### 3.2. Проекты

```sql
CREATE TYPE project_status AS ENUM ('active','paused','archived');

CREATE TABLE project (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    key            citext        NOT NULL UNIQUE,   -- genium-clean, angarachat
    name           text          NOT NULL,
    repo_path      text,
    default_branch text,
    asset_class    text,                            -- knowledge|product|infrastructure
    status         project_status NOT NULL DEFAULT 'active',
    autonomy       text NOT NULL DEFAULT 'human_gate'
                   CHECK (autonomy IN ('human_gate','auto')),
    external_ref   text,                            -- ключ в registry.json
    meta           jsonb        NOT NULL DEFAULT '{}',
    created_at     timestamptz  NOT NULL DEFAULT now(),
    updated_at     timestamptz  NOT NULL DEFAULT now()
);
```

`autonomy` — проектная политика приёмки: `human_gate` (по умолчанию) — агент
просит приёмки, человек закрывает; `auto` — агент в проекте с доверенной
автономией закрывает свои задачи сам. Это снимает тупик «в проекте ИИ работает
без человека, а приёмки нет».

### 3.3. Задачи — ядро

```sql
CREATE TYPE task_kind     AS ENUM ('task','bug','feature','chore','decision',
                                   'research','question','spike','risk');
CREATE TYPE task_status   AS ENUM ('backlog','todo','in_progress','blocked',
                                   'needs_input','in_review','done','cancelled');
CREATE TYPE task_priority AS ENUM ('p0','p1','p2','p3');

CREATE TABLE task (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ref              text          NOT NULL UNIQUE,   -- DSK-142
    project_id       uuid          REFERENCES project(id) ON DELETE SET NULL,
    parent_id        uuid          REFERENCES task(id)   ON DELETE SET NULL,
    kind             task_kind     NOT NULL DEFAULT 'task',
    status           task_status   NOT NULL DEFAULT 'backlog',
    priority         task_priority NOT NULL DEFAULT 'p2',
    title            text          NOT NULL,
    description      text          NOT NULL DEFAULT '',
    assignee_id      uuid          REFERENCES actor(id) ON DELETE SET NULL,
    requester_id     uuid          REFERENCES actor(id) ON DELETE SET NULL,
    reporter_id      uuid          REFERENCES actor(id) ON DELETE SET NULL,
    created_by_id    uuid          REFERENCES actor(id) ON DELETE SET NULL,
    due_at           timestamptz,
    estimate_minutes integer CHECK (estimate_minutes IS NULL OR estimate_minutes >= 0),
    spent_minutes    integer CHECK (spent_minutes    IS NULL OR spent_minutes    >= 0),
    blocked_reason   text,
    external_ref     text,          -- ветка, PR, внешний ключ
    source           text,          -- mattermost | teamboard | pm-global | api | agent
    source_ref       text,          -- обратная ссылка: post_id, json-путь
    labels           text[] NOT NULL DEFAULT '{}',
    meta             jsonb   NOT NULL DEFAULT '{}',
    version          integer NOT NULL DEFAULT 1,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    started_at       timestamptz,
    completed_at     timestamptz,
    deleted_at       timestamptz,
    CONSTRAINT task_no_self_parent CHECK (parent_id IS DISTINCT FROM id)
);

CREATE INDEX task_assignee_open_idx ON task(assignee_id, due_at)
    WHERE completed_at IS NULL AND status NOT IN ('done','cancelled');
CREATE INDEX task_project_status_idx ON task(project_id, status)
    WHERE deleted_at IS NULL;
CREATE INDEX task_due_idx           ON task(due_at)
    WHERE completed_at IS NULL AND status NOT IN ('done','cancelled');
CREATE INDEX task_labels_idx        ON task USING gin(labels);
CREATE INDEX task_meta_idx          ON task USING gin(meta);
CREATE INDEX task_title_trgm_idx    ON task USING gin(title gin_trgm_ops);
```

Почему так:

- **`kind` включает не-работу.** `decision`, `research`, `question`, `risk` —
  в агентной реальности результатом часто является *знание*, а не код. Задача
  «выяснить, почему падает релиз» — это `research`, а не `bug`.
- **`requester_id` и `reporter_id` разделены.** Заявитель — тот, кому важен
  результат (принимает приёмку). Автор — тот, кто завёл. Часто это разные
  люди: бота попросил Пётр, задачу завела Аня.
- **`external_ref` + `source` + `source_ref`** — трейлер происхождения. Позволяет
  идемпотентный импорт и дедупликацию (см. §7).
- **`version`** — оптимистичная блокировка: бот и человек правят одну задачу
  одновременно → не теряется ни одно изменение (PATCH требует `version`).
- **Нет `deleted_at` в уникальности `ref`** — `ref` остаётся записанным, чтобы
  не переиспользовать номер (важно для ссылок в чате).

### 3.4. Доказательства — мост к git

```sql
CREATE TYPE evidence_kind AS ENUM ('commit','branch','pr','file','url','doc',
                                   'note','review','test');

CREATE TABLE evidence (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id    uuid NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    kind       evidence_kind NOT NULL,
    ref        text NOT NULL,        -- sha / имя ветки / номер PR / путь
    uri        text,                 -- https://...
    title      text,
    note       text,
    author_id  uuid REFERENCES actor(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX evidence_task_idx ON evidence(task_id, created_at);
```

Трекер **не проверяет** существование commit'а и **не считает** diff. Он помнит.
Проверка — отдельная опциональная операция (`verification`), которую может
выполнить агент: «проверь, что задача закрыта и PR в main» → агент приносит
результат, трекер записывает.

### 3.5. Связи между задачами

```sql
CREATE TYPE link_kind AS ENUM ('blocks','blocked_by','relates_to','duplicates',
                               'implements','split_from','follows_up');

CREATE TABLE task_link (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    from_id       uuid NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    to_id         uuid NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    kind          link_kind NOT NULL,
    created_by_id uuid REFERENCES actor(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (from_id, to_id, kind),
    CHECK (from_id <> to_id)
);
```

`blocks` — то, чего нет ни в одной из трёх существующих систем и что нужно
реально: «эта задача блокирует релиз».

### 3.6. Комментарии и активность

```sql
CREATE TABLE comment (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id    uuid NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    parent_id  uuid REFERENCES comment(id) ON DELETE CASCADE,
    author_id  uuid REFERENCES actor(id) ON DELETE SET NULL,
    body       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    edited_at  timestamptz
);
CREATE INDEX comment_task_idx ON comment(task_id, created_at);

CREATE TYPE activity_action AS ENUM
  ('created','status_changed','assigned','unassigned','reassigned','commented',
   'evidence_added','due_changed','priority_changed','linked','unlinked',
   'review_requested','accepted','rejected','claimed','released','cancelled',
   'deleted','restored');

CREATE TABLE activity (
    id         bigserial PRIMARY KEY,
    task_id    uuid REFERENCES task(id) ON DELETE CASCADE,
    project_id uuid REFERENCES project(id) ON DELETE SET NULL,
    actor_id   uuid REFERENCES actor(id) ON DELETE SET NULL,
    action     activity_action NOT NULL,
    from_value text,
    to_value   text,
    summary    text,
    interface  text NOT NULL DEFAULT 'api',
    request_id text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX activity_task_idx    ON activity(task_id, created_at DESC);
CREATE INDEX activity_created_idx ON activity(created_at DESC);
CREATE INDEX activity_actor_idx   ON activity(actor_id, created_at DESC);
```

`activity` — append-only, без `UPDATE` и `DELETE` в коде приложения.
`interface` отвечает на вопрос «откуда это пришло» — это одновременно аудит
безопасности и метрика внедрения.

### 3.7. Учётные записи агентов

```sql
CREATE TABLE credential (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id      uuid NOT NULL REFERENCES actor(id) ON DELETE CASCADE,
    title         text NOT NULL,
    token_prefix  text NOT NULL,
    token_hash    text NOT NULL,
    scopes        text[] NOT NULL DEFAULT '{task:read,task:write}',
    project_scope uuid[],                 -- ограничить агента проектами
    can_assign    boolean NOT NULL DEFAULT false,  -- право назначать людей
    expires_at    timestamptz,
    last_used_at  timestamptz,
    revoked_at    timestamptz,
    created_by_id uuid REFERENCES actor(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX credential_actor_idx  ON credential(actor_id);
CREATE INDEX credential_prefix_idx ON credential(token_prefix);
```

**`can_assign` — центральное поле.** «Попросить бота назначить задачу на
кого угодно» — это операция, которой доверия быть не должно по умолчанию:
агент, который может назначать людям, может и завалить людей. Поэтому право
выдаётся **явно**, на конкретную учётку, и каждое такое назначение:
1. пишется в `activity` с `interface`,
2. вызывает DM-назначенному,
3. видно в интерфейсе как «назначено ботом».

### 3.8. Уведомления — outbox

```sql
CREATE TABLE notification (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id        uuid REFERENCES task(id) ON DELETE CASCADE,
    actor_id       uuid REFERENCES actor(id) ON DELETE SET NULL, -- кому
    channel        text NOT NULL,   -- mattermost_dm | mattermost_channel | webhook
    kind           text NOT NULL,   -- assigned | needs_input | due_soon | comment | accepted
    payload        jsonb NOT NULL DEFAULT '{}',
    delivery_state text NOT NULL DEFAULT 'pending'
                   CHECK (delivery_state IN ('pending','sent','failed','suppressed')),
    attempts       integer NOT NULL DEFAULT 0,
    last_error     text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    delivered_at   timestamptz
);
CREATE INDEX notification_pending_idx ON notification(created_at)
    WHERE delivery_state = 'pending';
```

API **никогда** не ходит в Mattermost синхронно. Запись в `notification`
в той же транзакции, что и изменение задачи; отдельный воркер разбирает очередь.
Mattermost упал — трекер работает, уведомления доедут позже.

### 3.9. Правила переходов — в базе

```sql
CREATE TABLE status_rule (
    kind        text NOT NULL DEFAULT 'task',
    from_status task_status NOT NULL,
    to_status   task_status NOT NULL,
    actor_kinds actor_kind[] NOT NULL,   -- кому разрешён переход
    requires    text[] NOT NULL DEFAULT '{}',
    description text,
    PRIMARY KEY (kind, from_status, to_status)
);
```

Машина состояний **конфигурируема**, а не зашита в код: её можно менять без
деплоя, а интерфейс умеет подсказывать только допустимые действия. Базовый
набор — в §4.

### 3.10. Полная карта

```
actor ──┬──< task (assignee)
        ├──< task (requester)
        ├──< task (reporter)
        ├──< task (created_by)
        ├──< actor (supervisor)          ← агенты отвечают перед людьми
        ├──< credential                  ← учётки агентов
        └──< notification                ← outbox

project ──< task ──┬──< evidence         ← ссылки на git/внешний мир
                  ├──< comment           ← треды обсуждения
                  ├──< activity          ← append-only журнал
                  └──< task_link         ← blocks / relates_to / …
```

---

## 4. Машина состояний

### 4.1. Переходы

| Из | В | Кто может | Требования |
|---|---|---|---|
| `backlog` | `todo` | human, agent | — |
| `backlog` | `cancelled` | human | причина |
| `todo` | `in_progress` | **agent** (claim) / human (accept) | назначенный или претендент |
| `todo` | `backlog` | human, agent | — |
| `in_progress` | `blocked` | agent, human | причина |
| `in_progress` | `needs_input` | agent, human | **вопрос**; уведомление заявителю и руководителю |
| `in_progress` | `in_review` | agent, human | резюме; желательно evidence |
| `in_progress` | `todo` | agent (release), human | — |
| `needs_input` | `in_progress` | **human** (от кого ждали) или руководитель | — |
| `needs_input` | `cancelled` | human | причина |
| `in_review` | `done` | **заявитель / руководитель / человек** | приёмка; агент — только при `autonomy='auto'` |
| `in_review` | `in_progress` | заявитель / руководитель | причина (отклонение) |
| `done` | `in_progress` | human | reopened |
| `cancelled` | `backlog` | human | — |

### 4.2. Три правила, которые стоят отдельного разговора

**R1. Агент не закрывает свою задачу сам.** Переход `in_review → done` доступен
агенту только в проектах с `autonomy='auto'`. Иначе — заявитель, руководитель
агента или любой человек с правом приёмки.

Почему: если агент может закрыть сам, метрика «закрыто» перестаёт быть
проверяемой. Это ровно та эпистемическая честность, которая в этом estate уже
проводится в отчётах (`Teamboard/AGENTS.md:284`).

**R2. `needs_input` — это не «застрял».** Это явное состояние «я остановился и
жду конкретного ответа». Оно обязано быть адресным: задача хранит вопрос, а
уведомление уходит тому, к чьему ответу ждут. Иначе «нужна информация»
превращается в тихое замирание.

**R3. Задача без заявителя.** Если заявителя нет (бота попросили в чате, он
завёл задачу сам), приёмку делает руководитель актора-исполнителя; если и его
нет — любой человек-администратор. Иначе такие задачи висяли бы вечно.

---

## 5. Идентичность

### 5.1. Нормализация

```
normalize(s):
  s = s.strip().lstrip('@')
  s = s.lower()
  s = s.replace('ё','е')
  s = re.sub(r'\s+',' ', s)
```

### 5.2. Алгоритм разрешения

```
resolve(principal, raw) -> actor:
  1. raw in ('me','я','мне')            → principal
  2. actor.handle == normalize(raw)     → actor
  3. alias (namespace=principal_ns)     → actor      # 'mattermost' для людей
  4. alias (любой namespace)            → actor + дописать alias в текущий ns
  5. actor.display_name == normalize(raw) → actor
  6. иначе → создать actor(kind='placeholder', unresolved=true)
```

Пункт 5 — то, что закрывает сегодняшний `Пётр` (отображаемое имя) против
`petr` (логин).

### 5.3. Наполнение

| Источник | Что берём | Как |
|---|---|---|
| Mattermost API | 23 активных пользователя | `position != ''` **или** почта в домене `@localhost` ⇒ `kind='agent'`, иначе `kind='human'`; `handle` = username; `display_name` = first+last |
| Teamboard `registry.json` | 54 проекта | `project.key` = id, `repo_path`, `asset_class` |
| Teamboard `annotations.json` | 97 суждений | → задачи (см. §7) |
| Git-конфиги | email → handle | alias namespace `git` |

Ключ актёра в базе — пара `(source, source_ref)`: `source` — откуда пришёл
(`mattermost`, `manual`, …), `source_ref` — идентификатор объекта в
источнике (`id` пользователя Mattermost). Пара уникальна, поэтому импорт
идемпотентен: повторный прогон обновляет те же строки, а не заводит новые
(§10.2). Актёры, созданные вручную, источника не имеют и в уникальность не
попадают.

Различатель «человек / агент» в Mattermost — это **должность или служебный
адрес**, а не только должность. Первая версия этого правила («`position` непустое
только у ботов») на живой базе не подтвердилась: у трёх служебных учётных записей
(`calls`, `system-bot`, `kb-publisher`) должность пуста. Проверка 23 активных
пользователей даёт 10 агентов (`board`, `calls`, `comrade`, `findings-reporter`,
`legist`, `norma`, `pm-reporter`, `sibres-site`, `system-bot`, `triage`) и
13 человек. Служебный домен `@localhost` — признак бота; `kb-publisher` в нём
не значится и остаётся человеком.

Из каждого пользователя заводится три алиаса: логин (`petr`), полное имя
(`Пётр Косов`) и имя без фамилии (`Пётр`). Последнее обязателен: в чужих
данных человека называют по имени, и без него «Пётр» не разрешился бы в
«Пётр Косов» — §5.2 сравнивает полное отображаемое имя.

---

## 6. Интерфейсы

### 6.0. Слои: домен → сервис → интерфейс

Правило поведения должно быть одно на все интерфейсы, а не по копии на
интерфейс:

```
src/domain/     правила и типы: что можно и что нельзя; ни БД, ни HTTP
src/service/    use case'ы: правило применяется к данным, пишется журнал,
                транзакция; отказ — значение закрытого типа
src/api|mcp|cli интерфейсы: разобрать запрос, вызвать сервис, перевести
                отказ в ответ своего протокола
```

Слой сервиса введён 20.11.2026 (решение D5). До этого use case'ы задач жили
в HTTP-обработчике: правило перехода пришлось бы повторять в MCP и CLI, а
журнал писал интерфейс константой — агентский вызов был неотличим от
человеческого.

Что из этого следует:

- **Правило живёт в домене, применение — в сервисе.** Домен не знает про БД;
  сервис знает про БД, но не про HTTP. Отказ сервиса — значение закрытого
  типа (`bad_request`, `forbidden`, `not_found`, `conflict`, `storage`), а не
  строка: иначе «правило запрещает» не отличить от «сломалось хранилище».
- **Журнал помнит интерфейс.** `activity.interface` — закрытый вариант
  (`api`, `mcp`, `cli`, `web`, `mattermost`, `paseo`, `import`, `system`),
  а не строка: иначе агентский вызов не отличить от человеческого.
- **Интерфейс — адаптер.** HTTP не применяет правила сам и не пишет в базу
  напрямую; он переводит класс отказа в код ответа своего протокола.

### 6.1. REST API

```
GET    /api/v1/tasks                    ?project=&assignee=&status=&kind=
                                       &due=&q=&label=&limit=&cursor=
GET    /api/v1/tasks/mine               ← главный запрос: мои задачи по всем проектам
GET    /api/v1/tasks/{ref}
POST   /api/v1/tasks
PATCH  /api/v1/tasks/{ref}              (If-Match: version)
POST   /api/v1/tasks/{ref}/transition    {to, reason?, version}
POST   /api/v1/tasks/{ref}/claim         {version, reason?}
POST   /api/v1/tasks/{ref}/release       {version, reason?}
POST   /api/v1/tasks/{ref}/assign        {assignee}
POST   /api/v1/tasks/{ref}/comment
POST   /api/v1/tasks/{ref}/evidence
POST   /api/v1/tasks/{ref}/links
GET    /api/v1/projects
POST   /api/v1/projects
GET    /api/v1/actors
POST   /api/v1/actors/{id}/aliases
POST   /api/v1/actors/resolve            {raw, namespace?} → actor | placeholder
GET    /api/v1/activity                  ?project=&task=&since=&actor=
GET    /api/v1/credentials
POST   /api/v1/credentials               → выдать токен агенту
DELETE /api/v1/credentials/{id}
GET    /api/v1/overview                  → сводка: WIP, застрявшие, по людям
GET    /api/v1/healthz
```

**Главный запрос** (`/tasks/mine`) — то, ради чего всё затевается:

```sql
SELECT t.*, p.key AS project_key, a.display_name AS assignee_name
FROM task t
LEFT JOIN project p ON p.id = t.project_id
LEFT JOIN actor a   ON a.id = t.assignee_id
WHERE t.assignee_id = :me
  AND t.deleted_at IS NULL
  AND t.completed_at IS NULL
  AND t.status NOT IN ('done','cancelled')
ORDER BY
  CASE WHEN t.due_at IS NULL      THEN 3
       WHEN t.due_at <  now()      THEN 0
       WHEN t.due_at <  now()+interval '1 day' THEN 1
       ELSE 2 END,
  COALESCE(t.due_at, 'infinity'::timestamptz),
  t.priority,
  t.created_at,
  t.id;
```

Уточнения к главному запросу:

- **«Мои» — это исполнитель.** `:me` берётся из заголовка актора
  (`x-doska-actor`), а не из тела запроса: клиент не может спросить «мои
  задачи» чужого человека. Задачи всех проектов — проекта в фильтре нет.
- **Открытые — по трём признакам сразу.** Задача должна быть не удалена
  (`deleted_at IS NULL`), не завершена (`completed_at IS NULL`) и иметь
  статус не из `done`/`cancelled`. Любой из трёх признаков означает, что
  задача закрыта для работы.
- **Порядок — по срочности, четырьмя корзинами.** 0 — просрочено,
  1 — срок в ближайшие сутки, 2 — срок позже, 3 — срока нет. Внутри
  корзины — по самому сроку, затем приоритет, затем давность, затем
  идентификатор.
- **`COALESCE(t.due_at, 'infinity'::timestamptz)`, а не `NULLS LAST`.**
  В сравнении кортежей Postgres даёт для NULL «неизвестно», а не
  «больше»: с чистым `t.due_at` задачи без срока нельзя было бы
  расставить между собой, и курсорная пагинация по ключу порядка была бы
  некорректной. `infinity` больше любого настоящего момента — тот же
  порядок, что давал `NULLS LAST`, но сравнимый.
- **Идентификатор в конце ключа** — чтобы порядок был полным. Без него
  равные по остальным признакам строки переставлялись бы между
  страницами, и пагинация могла бы повторить или потерять строку.
- **Курсор — идентификатор последней выданной задачи.** Следующая
  страница начинается со строго следующей по ключу порядка. Неверный
  курсор (не uuid) игнорируется, а курсор на несуществующую задачу даёт
  пустую страницу — так же, как в `GET /tasks`.
- **Ответ:** `{"items": [...], "next_cursor": "..." | null, "limit": N}`.

**Заявка и отпуск** (`/tasks/claim`, `/tasks/release`) — как агент берёт
задачу в работу и как возвращает её в пул:

```
POST /api/v1/tasks/{ref}/claim   {version, reason?}
POST /api/v1/tasks/{ref}/release {version, reason?}
→ 200 {"task": {...}}
```

Уточнения к заявке и отпуску:

- **Заявка — только из `todo`.** Задача в любом другом статусе не заявляема:
  ответ 409 с текстом «задача в статусе X: заявка — только из статуса todo».
  Неверное состояние лечится повторным чтением, а не новым правилом.
- **Заявку может подать любой агент, но не всякая задача — его.** Правило
  `todo → in_progress` — «назначенный или претендент» (§4.1): свободную
  задачу (`assignee_id IS NULL`) берёт любой агент, назначенную — только её
  исполнитель. Чужая задача — 403.
- **Заявка не отменяет назначение.** Если задача уже назначена, исполнитель
  после заявки остаётся прежним; если была свободна — становится
  претендентом. Смысл: назначение — это обязательство, а не подпись
  «времянно сдал на тебя».
- **Отпуск — только из `in_progress`, и всегда возвращает в пул.**
  Исполнитель снимается (`assignee := NULL`), статус становится `todo`:
  задача снова свободна. Отпустить может исполнитель-агент или любой
  человек; посторонний агент — 403.
- **Версия обязательна.** Тело — `{version, reason?}`: без `version` — 400,
  с устаревшей версией — 409. Это оптимистичная блокировка: она и есть
  механизм взаимного исключения двух претендентов. Без неё заявка была бы
  гонкой, а не блокировкой.
- **Отказ правила — 403, отказ состояния — 409.** Нарушение правила
  (чужой агент) не лечится повторным чтением; неверное состояние лечится.
  Разные статусы — разные причины отказа.
- **Журнал:** `claimed` при заявке, `released` при отпуске. Оба значения
  уже были в перечислении `activity_action` с самого начала.

### 6.2. MCP — контракт с агентами

Транспорт: streamable HTTP на `/mcp` + stdio-мост для агентов, умеющих только
stdio (мостик из `agent-kanban` — как раз удачное решение, его стоит
переиспользовать).

| Инструмент | Смысл | Ключевые аргументы |
|---|---|---|
| `whoami` | кто я, что мне можно, что значит «мои» | — |
| `my_tasks` | мои задачи по всем проектам, сгруппированные | `include_done` |
| `list_tasks` | поиск по выборке | `project, assignee, status, kind, due, query, limit` |
| `get_task` | одна задача со всеми связями | `ref` |
| `create_task` | завести задачу | `title, project?, description?, assignee?, kind?, priority?, due_at?, requester?` |
| `claim_task` | взять задачу в работу | `ref` |
| `release_task` | вернуть в пул | `ref, reason?` |
| `assign_task` | **назначить на кого угодно** | `ref, assignee, note?` |
| `update_task` | изменить поля | `ref, status?, priority?, due_at?, description?, title?` |
| `comment_on_task` | комментарий | `ref, body, parent_id?` |
| `add_evidence` | приложить ссылку | `ref, kind, ref_value, uri?, note?` |
| `request_review` | попросить приёмки | `ref, summary` |
| `complete_task` | закрыть (может быть отклонено правилами) | `ref` |
| `list_projects` | проекты | `status?` |
| `activity_feed` | что изменилось | `project?, since?, limit?` |
| `search_tasks` | полнотекстовый поиск | `query, limit?` |

16 инструментов. Отличия от `subroutine` (по материалам анализа):
`assign_task` и `create_task` **разделены** и **по-разному ограничены правами**;
`complete_task` может быть отклонён сервером по правилам переходов; `whoami`
объясняет ограничения, а не просто возвращает имя.

**MCP-слой пишется вручную — SDK для OCaml нет.** В закреплённом nixpkgs нет ни
`mcp`, ни `mcp-server`, поэтому JSON-RPC 2.0 реализуется на `yojson` (~300 строк,
§9.1). Это единственный способ не тащить непроверенную зависимость в ядро, но
контракт от этого не становится мягче — он фиксируется явно:

- `protocolVersion` согласуется на `initialize` и возвращается клиенту; при
  несовпадении версий — явная ошибка, а не тихий фолбэк;
- `tools/call` при бизнес-ошибке (запрещённый переход, нет прав на назначение)
  возвращает `isError: true` с читаемым сообщением, а не HTTP 500;
- JSON Schema аргументов каждого инструмента собирается из одного описания —
  `tools/list` и валидация не могут разойтись;
- транспорт — streamable HTTP `/mcp`; stdio-мост переписывается на OCaml (идея
  из `agent-kanban`: один файл, только пересылка stdin/stdout, без своего
  протокола).

### 6.3. CLI `tk`

Для людей в терминале и для ботов (по образцу `mm`):

```
tk list [--mine|--all] [--project X] [--status S] [--assignee A] [--due soon]
tk show <ref> [--comments] [--activity]
tk add "текст" [--project X] [--assignee A] [--due 2026-11-20] [--kind K]
tk assign <ref> <actor> [--note "..."]
tk claim <ref> / tk release <ref> / tk done <ref> [--summary "..."]
tk comment <ref> "текст"
tk whoami
tk watch [--project X]        # живая лента активности
```

`tk` попадает в PATH через Nix — и в песочницу ботов тоже (как сейчас `mm`).

### 6.4. Веб-интерфейс

| Экран | Содержание |
|---|---|
| **Мои задачи** (по умолчанию) | группы: просрочено / сегодня / неделя / позже / без срока / ждут меня |
| **Доска проекта** | колонки по статусам, drag&drop, фильтры по исполнителю и виду |
| **Карточка задачи** | описание, статус, исполнитель, срок, доказательства, комментарии, лента активности, связи |
| **Обзор** | WIP по людям и агентам, что застряло, возраст `needs_input`, нагрузка по проектам |
| **Админ** | акторы и алиасы (включая placeholders), проекты, учётки агентов, правила переходов |

Стек: **веб-компоненты на чистом JavaScript (ES2022), D3.js — единственная
runtime-зависимость.** Без TypeScript, без сборщика, без VDOM. Тёмная тема по
умолчанию. Решение владельца от 19.11.2026 — D4 в §13, детали стека — §9.1.

**Фронтенд отражает функциональную модель бэкенда, а не повторяет её в VDOM.**
Состояние — одно неизменяемое значение; редьюсеры — чистые функции
`(state, action) => state`; компонент — чистая функция от состояния, а DOM —
её проекция. Ошибка — значение, а не исключение: та же дисциплина `Result`,
что на сервере, только без статической типизации.

| Что | Как |
|---|---|
| Элемент компонента | один компонент — один custom element (`CustomElementRegistry`) |
| Изоляция | Shadow DOM по умолчанию; light DOM — явное исключение `createRenderRoot() { return this; }` для компонентов, в которые рисует D3 |
| Тема | CSS custom properties — наследуются сквозь границу Shadow DOM; внешний доступ к частям — `::part()` |
| Визуализации | D3.js рисует по данным и **не мутирует состояние** |
| Тесты | чистые функции (редьюсеры, форматтеры, экранирование) — встроенным `node --test`, без зависимостей; компоненты — живой проверкой в браузере |

Данные для визуализаций — `GET /api/v1/overview` (§6.1) и экран «Обзор»: WIP
по людям и агентам, что застряло, возраст `needs_input`, нагрузка по проектам.
Это самые «навороченные» экраны, и они строятся на D3.js, а не на
самописном SVG.

**Запасной лёгкий фреймворк — Lit** (~6 КБ, построен на веб-компонентах, без
VDOM), если объём ручного кода станет неподъёмным. Preact отклонён: VDOM
дублирует модель. Alpine отклонён: директивы, а не компоненты. Любая новая
зависимость требует отдельной записи в ADR с обоснованием.

Компоненты `agent-kanban/web` не переиспользуются: там `div` и inline-стили, а
стек теперь другой. В Mattermost/Paseo их всё равно было бы не переиспользовать.

### 6.5. Обновления в реальном времени

Postgres `LISTEN/NOTIFY` → WebSocket-канал в API → веб (живая доска) и
`tk watch`. Без отдельного брокера.

---

## 7. Интеграции

### 7.1. Mattermost

**Основной путь — боты, а не плагин.** Go в estate не установлен (только в
nixpkgs), поэтому Mattermost-плагин на Go — это отдельный сборочный конвейер.
Сначала путь, который работает сразу:

| Механизм | Что делает |
|---|---|
| `tk` в песочнице бота | бот умеет заводить, назначать, комментировать |
| Правила в `AGENTS.md` ботов | «назначь задачу на @petr» → `tk assign`; «что у меня» → `tk list --mine` |
| Slash-команды `/tasks`, `/assign`, `/task` | через существующий `bot-gateway` |
| Интерактивные карточки | кнопки «Взять», «Нужна информация», «Готово», «Отклонить» → callback в трекер |
| DM-уведомления | из outbox: назначение, `needs_input`, срок скоро, комментарий |

Плагин Mattermost (отдельным этапом, Go): постоянная панель «Мои задачи»,
карточка задачи прямо в треде, кнопки без чата. К этому моменту API трекера
уже стабилен, а плагин — тонкая обёртка.

### 7.2. Paseo

| Возможность SDK | Применение |
|---|---|
| Плагин-панель (клиент плагина, React Native) | «Мои задачи» прямо в Paseo |
| `addHook('agent.turn.before')` | подставить текущую задачу агента в контекст |
| `addHook('agent.close.after')` | освободить claim, если агент не закрыл |
| `addHook('agent.create.before')` | спросить, какую задачу взять |

Образец структуры — `PaseoPlugins/yeah-provider` (`paseo-plugin.json` +
`index.server.ts` + `server/` + `shared/` + `test/`).

### 7.3. Teamboard

Остаётся **измерителем**. Трекер читает его `registry.json` (проекты) и
`annotations.json` (суждения) — **один раз, при импорте**, дальше у трекера своя
копия. Обратная связь: трекер может отдать в Teamboard ссылку на задачу
(расширение `annotations`), чтобы карточки и задачи не расползались.

### 7.4. pm-global (дневной план)

Сейчас «Планы на завтра» — пять пунктов прозой, которые умирают вместе с
отчётом. Новая схема:

1. Планировщик формирует **структурированный** план (JSON: проект, исполнитель,
   срок, тип), а не буллеты.
2. Планировщик пишет задачи в трекер через API (идемпотентно, по `source_ref`).
3. Отчёт в канале рендерится **из трекера** — это уже не новый текст, а живая
   выборка. Пункт, который уже есть в трекере, помечается выполненным, а не
   переписывается.

Это самое болезненное место сегодня: план рождается текстом и умирает.

### 7.5. Git

Трекер **не запускает git**. Два тонких места:

- **Ссылка на ветку** при переводе задачи в `in_progress`: агент сам сообщает
  `branch` → `evidence(kind='branch')`. Трекер проверяет только формат.
- **Проверка приёмки** (опционально): агент может принести `verification` —
  sha, tree hash, результат тестов. Записывается как evidence.

Если позже понадобится, отдельный **инжестор** (не часть ядра) будет читать
git и дописывать факты. Но ядро от git не зависит — это и было требованием к
`agent-kanban`.

---

## 8. Безопасность

| Слой | Решение |
|---|---|
| Люди | сессия в браузере (JWT в httpOnly-cookie) + magic-link вход, как в `subroutine-auth-bridge` (рабочий образец) |
| Агенты | bearer-токены, хэш в базе, `token_prefix` для показа, `scopes`, `project_scope`, срок |
| `can_assign` | отдельный явный грант на учётку, по умолчанию `false` |
| Право закрывать | зашито в машину состояний, а не в UI |
| Аудит | `activity` — append-only, с `actor_id` и `interface` |
| Секреты | `/etc/secrets/<имя>/`, 0600, root:root; в Nix — только пути, не значения |
| Веб | reverse proxy (Caddy) + HTTPS; API не торчит наружу, только `127.0.0.1` |
| Анти-спам | лимит задач на учётку в час; дедуп по `(source, source_ref)`; агентские задачи по умолчанию `backlog` |

---

## 9. Развёртывание

### 9.1. Стек: OCaml

Решение владельца от 17.11.2026: трекер пишется на **OCaml**. Проверенные версии
против пин-нина estate (`nixpkgs` rev `b6018f87`, ветка 25.11) — все пакеты
разрешаются, ничего не придётся вендорить:

| Пакет | Версия | Роль в трекере |
|---|---|---|
| `ocaml` | 5.3.0 | компилятор; эффекты — основа конкурентности |
| `dune_3` | 3.20.2 | сборка |
| `dream` | 1.0.0-alpha8 | HTTP-сервер: REST, `/mcp`, WebSocket |
| `lwt` | 5.9.2 | асинхронность |
| `caqti` + `caqti-driver-postgresql` | 2.2.4 | PostgreSQL |
| `core` / `base` | 0.17.1 / 0.17.2 | домен: `Result`, `Time`, `Map`, `Lock` |
| `yojson` + `ppx_yojson_conv` | 0.17.1 | JSON и ppx-деривация |
| `cmdliner` | 1.3.0 | CLI `doska` |
| `alcotest` | 1.9.1 | тесты |
| `ocamlformat`, `ocaml-lsp` | — | гигиена и навигация |

Фронтенд — **веб-компоненты на чистом JavaScript + D3.js** (решение D4 от
19.11.2026). React, Vite и TypeScript из стека убраны.

`js_of_ocaml` в nixpkgs есть, но OCaml-сервер и браузерный клиент — разные
среды: общаются они по REST, а клиент остаётся на том, что браузер понимает
нативно. Выигрывает здесь не плотность фреймворка, а соответствие модели:
фронтенд **отражает функциональную дисциплину бэкенда** — чистые функции,
неизменяемое состояние, ошибка как значение — и обходится без сборщика и без
VDOM. D3.js — единственная runtime-зависимость, и та leaf: она рисует по
данным, состояние не мутирует.

Обоснование и границы — §6.4, решение D4 — §13.

#### Почему OCaml здесь сильнее, а не просто «так решили»

1. **Стейт-машина проверяется компилятором.** Статусы — полиморфные варианты,
   переходы — `match` с `[@@@warning "-8"]`. Добавил новый статус → компилятор
   требует обновить все места, где статус разбирается. В Python или TS таблица
   переходов остаётся данными, которые молча расходятся с кодом.
2. **Домен отделён от эффектов.** `src/domain/` не знает ни про БД, ни про HTTP.
   Переходы, правила приёмки и правила назначения тестируются чисто, без БД —
   это самые ценные тесты в системе, и они бесплатны по времени.
3. **Один бинарник вместо интерпретатора.** `pkgsStatic.ocamlPackages` — уже
   применяется в estate (`math-coding`). Демон без интерпретатора, ~40–60 МБ
   RSS, без зависимостей в рантайме. Прямой ответ на урок `agent-kanban`:
   13 агентов с keep-alive роняли Caddy в 502.
   Оговорка: полная статичность невозможна из-за отсутствия `libpq.a` —
   см. «Ограничение статической линковки» ниже.
4. **`Result` вместо исключений.** «Переход запрещён» — это значение
   `(Error (Forbidden_by_rules ...))`, а не исключение, которое надо не забыть
   поймать. Домен не бросает.
5. **Сервер и CLI — один артефакт.** `doska serve` и `doska list` собираются
   из одного `bin/`, одна точка сборки, одна версия.

#### Модульная структура

Проект разложен по **отдельным библиотекам dune**, а не по каталогам внутри
одной библиотеки. Причина не в эстетике: dune не включает модули из
подкаталогов в библиотеку автоматически, а объединение всего в один `lib`
делает «чистый домен» декларацией, а не ограничением компилятора. Отдельные
библиотеки превращают правило «домен не знает про БД» в зависимость, которую
dune не даст нарушить молча.

```
src/
├── domain/         библиотека `domain`: чистый домен, ни БД, ни HTTP, ни сети
│   ├── actor.ml          люди, агенты, алиасы, supervisor
│   ├── project.ml        проекты и autonomy
│   ├── task.ml           ядро: обязательство
│   ├── status.ml         статусы (полиморфные варианты)
│   ├── rules.ml          правила: кто что может (assign, close, accept) + R1–R3
│   ├── evidence.ml       ссылки на git/внешний мир
│   ├── interface.ml      откуда пришло действие: api / mcp / cli / web / …
│   └── activity.ml       события журнала
├── identity/       библиотека `identity`: normalize + resolve (алиасы → актор)
│   └── admin.ml          список администраторов из окружения, право is_admin
├── service/        библиотека `service`: use case'ы — правило применяется
│   │                к данным, транзакция и журнал в одном месте (§6.0)
│   ├── failure.ml        закрытый тип отказа: bad_request / forbidden / …
│   └── task.ml           use case'ы задач: list, get, create, patch,
│                         transition, assign, comment, evidence
├── db/             библиотека `db`: caqti, DDL, миграции, репозитории
│   ├── conn.ml           подключение, quote, exec
│   ├── migrate.ml        свой мигратор (см. ниже)
│   └── repo_*.ml         actor / task / project / evidence / activity
├── api/            библиотека `api`: dream — REST, WebSocket, auth, CORS
├── mcp/            библиотека `mcp`: JSON-RPC 2.0 + 16 инструментов
├── notify/         библиотека `notify`: outbox-воркер (разбор очереди → Mattermost)
├── integrations/   библиотека `integrations`: mattermost / teamboard_import / pm_global
├── version/        библиотека `version`: имя и версия в одном месте
└── bin/
    └── doska.ml    cmdliner: `doska serve | migrate | health | version`
```

Фактическое состояние на 20.11.2026: реализованы `domain` (`status`,
`actor`, `task`, `rules`, `interface`), `identity` (`resolve`, `admin`),
`db` (`conn`, `migrate`, `repo_*`), `service` (`failure`, `task` — D5),
`api` (`server`, `tasks`), `version` и `bin/doska.ml`. Остальные каталоги
(`mcp`, `notify`, `integrations`) — этапы 4, 6, 7.

Два ограничения dune, которые нашлись при сборке и зафиксированы здесь,
чтобы не переоткрывать их:

1. **Внутри библиотеки нельзя ссылаться на её собственный wrapper-модуль.**
   `src/db/migrate.ml` не может обратиться к `Db.Conn` — dune отвечает
   «Module Migrate … depends on Db. This doesn't make sense to me». Поэтому
   внутри `db` используется `Conn.*` напрямую, а `Db.Conn` — снаружи.
2. **Имена модулей не могут совпадать с именами каталогов-библиотек**
   в плоском виде: `status.ml` в `domain` даёт модуль `Domain.Status`, а
   не `Status`.

#### Ограничение статической линковки: нет `libpq.a`

Пункт 3 в «Почему OCaml здесь сильнее» обещает один статический бинарник без
зависимостей в рантайме. Для OCaml-сервера это верно, но **полностью
статичный бинарник с Postgres-драйвером получить нельзя**: в nixpkgs нет
статической `libpq.a` — только `libpq.so`. Проверено: `postgresql_17.lib`
содержит разделяемую библиотеку, статической нет.

Практические следствия, которые надо учесть при деплое:

- `pkgsStatic.ocamlPackages` применим к чистому OCaml-коду, но бинарник,
  линкующий `caqti-driver-postgresql`, останется **динамическим** против
  `libpq` из store.
- Альтернативы, если полная статичность понадобится: (а) свой чистый
  реализация протокола Postgres поверх Unix-сокета (больше работы, риск
  совместимости); (б) `postgresql` со встроенным сервером в одном процессе —
  отвергнуто, это противоречит принципу «не плодить тяжёлые демоны»;
  (в) принять динамическую линковку против `libpq` из nix store и закрыть
  зависимость через `runtimeInputs` NixOS-модуля.
- **Принято решение (в)**: бинарник динамический, зависимость от `libpq`
  объявляется в NixOS-модуле явно. Это осознанный размен «один артефакт без
  зависимостей» на «один артефакт с одной объявленной зависимостью».


#### Что придётся написать самим — в nixpkgs нет

| Чего нет | Что делаем | Объём |
|---|---|---|
| MCP-SDK для OCaml (`mcp`, `mcp-server` — отсутствуют) | JSON-RPC 2.0 поверх HTTP: `initialize`, `tools/list`, `tools/call`, согласование версии протокола | ~300 строк на `yojson` |
| Мигратор (`squash` — отсутствует) | упорядоченные `.sql` + таблица `schema_version`, применение в `ExecStartPre` | ~100 строк |
| OCaml-SDK для Mattermost | REST-вызовы `/api/v4/...` через `curl`/`Dream` | ~150 строк |

Остальное — наштатные библиотеки.

---

### 9.2. Топология

```
                    ┌───────────── Caddy ─────────────┐
   https://<домен> ─┤  /          → 127.0.0.1:8500    │  веб + API + /mcp
                    └──────────────┬───────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │  doska.service (OCaml)           │
                    │  dream :8500                      │
                    │  ├─ REST /api/v1                   │
                    │  ├─ MCP  /mcp                      │
                    │  └─ WS   /ws                       │
                    └──────────────┬───────────────────┘
                                   │ caqti
                    ┌──────────────▼───────────────────┐
                    │  PostgreSQL 17 (тот же инстанс)   │
                    │  база doska, пользователь doska│
                    │  ┌──────────┐  ┌───────────────┐ │
                    │  │doska-db│  │doska-outbox │ │  воркер уведомлений
                    │  └──────────┘  └───────────────┘ │  (отдельный таймер)
                    └──────────────────────────────────┘
```

- **systemd**: `doska.service` (Type=simple, `StateDirectory=doska`,
  `MemoryHigh=200M` / `MemoryMax=400M` — бинарник без интерпретатора ест мало) +
  `doska-outbox.timer` (раз в минуту).
- **Postgres**: `services.postgresql.ensureDatabases` / `ensureUsers` — есть в
  nixpkgs этого хоста, проверено.
- **Миграции**: свой мигратор (`src/db/migrate.ml`), упорядоченные `.sql` +
  таблица `schema_version`, вызов в `ExecStartPre` до старта сервера.
  Драйвер работает по extended protocol и не допускает несколько операторов в
  одном запросе, поэтому мигратор сам делит файл на выражения (учёт строковых
  литералов, `--`/`/* */` комментариев и `$$`-блоков) и выполняет их по
  одному внутри одной транзакции на файл.
  В `schema_version` пишется контрольная сумма файла; при следующем запуске
  мигратор сверяет её с диском и **отказывается работать**, если применённый
  файл изменился: у базы и у репозитория разные представления о схеме, и
  тихая рассинхронизация здесь дороже всего обойдётся.
  Типы в SQL создаются через `DO`-блок с обработкой `duplicate_object` —
  в Postgres нет `CREATE TYPE IF NOT EXISTS`, и без такой обёртки файл не
  переиграть на частично применённой базе.
- **NixOS-модуль**: `services.doska.*` в AngaraConfig — по образцу
  `services/subroutine.nix` (options, `mkIf`, `StateDirectory`, `systemd`).
- **Vhost**: запись в карте `kosov-reverse-proxy` в `configuration.nix`.
- **Сборка**: `buildDunePackage` со `pkgsStatic.ocamlPackages`; в рантайме не
  нужны ни Python, ни библиотеки OCaml. **Оговорка:** бинарник, линкующий
  `caqti-driver-postgresql`, остаётся динамическим против `libpq` из store —
  статической `libpq.a` в nixpkgs нет (см. «Ограничение статической линковки»).
  Фронт — **статика как есть**: нативные ES-модули и веб-компоненты, без
  сборщика. Ни `pnpm build`, ни nodejs в рантайме не нужны; node остаётся
  только в dev-оболочке — для тестов фронтенда (`node --test`).
- **Сеть**: `dream` по умолчанию слушает `localhost`, который на этом хосте
  резолвится в **IPv6 `::1` только** — IPv4 `127.0.0.1` получает
  `Connection refused` (проверено на этапе 0). Для Caddy, который ходит по
  IPv4, это надо учитывать: либо `0.0.0.0`, либо явный `::` в адресе
  прослушивания.
- **Память**: `agent-kanban` умер от 13 параллельных агентов с keep-alive. Здесь
  MCP — один процесс, соединения без keep-alive по умолчанию, лимит тела
  запроса. Бинарник без интерпретатора стартует мгновенно и не держит
  рантайм в памяти.

---

## 10. Миграция с текущего состояния

### 10.1. Что переносим

| Источник | Объём | Куда |
|---|---|---|
| `Teamboard/data/board/registry.json` | 54 проекта | `project` |
| `Teamboard/data/board/annotations.json` | 97 суждений | `task` (kind по `kind`, `assignee` ← канонизированный `owner`, `description` ← `why`, evidence ← `evidence`) |
| `Teamboard/data/board/epics.json` | 20 инициатив, 75 критериев | `task(kind='decision')` + `task_link` |
| `pm-global` планы | ~5 пунктов × 3 раза в день | `task` (idempotent по `source_ref`) |
| Mattermost | 22 пользователя | `actor` + `actor_alias` |
| `board.json` (192 карточки) | — | **не переносим**: это измерение git, не обязательства. Только ссылки на совпавшие задачи |

### 10.2. Идемпотентность

Каждый импорт имеет `source` + `source_ref` (уникальный ключ источника). Повторный
запуск обновляет, а не дублирует. Импорт запускается как `doska import
--source teamboard` и может выполняться сколько угодно раз.

### 10.3. Канонизация владельцев

Порядок для каждого `owner` из annotations: `resolve()` из §5.2. Если не
распознан — `placeholder` с `unresolved=true`. Отчёт импорта показывает
список нераспознанных — это и есть список «Пётр» vs `Петр` vs `peter`,
который надо закрыть руками.

---

## 11. Этапы

| Этап | Что | Готово, когда |
|---|---|---|
| **0. Каркас** | репозиторий, OCaml-тулчейн (dune 3.20, `ocaml 5.3`), статическая сборка через `buildDunePackage` + `pkgsStatic.ocamlPackages`, Nix-деплой, база Postgres, собственный мигратор, пустой API, healthz | `doska.service` active, `/healthz` 200 |
| **1. Схема и API** | actor/project/task/evidence/activity, переходы, временная идентификация по заголовку `X-Doska-Actor` | тесты на переходы и на R1 (агент не закрывает сам) |
| **2. Идентичность** | импорт Mattermost, алиасы, резолвер, placeholders | 23 актора; `/actors/resolve` отвечает на всех 97 строках annotations (52 непустых owner разрешены, 45 пустых — 400) |
| **3. Миграция** | импорт registry + annotations + epics | 97 задач, повторный импорт не создаёт дублей |
| **4. Агенты** | MCP-сервер, 16 инструментов, учётки и bearer-токены, `doska` | агент создаёт, берёт и комментирует задачу через MCP |
| **5. Люди** | веб на веб-компонентах (мои задачи, доска, карточка, обзор), ICS-календарь | человек видит свои задачи в браузере и в календаре |
| **6. Чат** | slash-команды, правила ботов, карточки с кнопками, DM | «назначь Пётру задачу» → задача создана, Пётр получил DM |
| **7. План дня** | pm-global пишет в трекер, отчёт рендерится из трекера | пункт плана — задача со сроком и исполнителем |
| **8. Paseo** | плагин-панель + хуки | задача агента видна в Paseo, claim освобождается при закрытии |
| **9. Чистка** | удаление `subroutine`, выпиливание его nix/секретов/vhost | `subroutine.service` отсутствует, Caddy без его маршрутов |
| **10. Плагин MM** (по D3 — позже) | Go-плагин Mattermost: панель «Мои задачи», карточка в треде | постоянная панель работает; критический путь к ней не зависит |

**Этап 9 — в конце, а не в начале**: пока трекер пуст, `subroutine` не мешает, а
его удаление ломает мост авторизации и bridge с Paseo раньше, чем замена готова.

**Этап 10 — по решению D3**: бот-путь (этап 6) закрывает потребность в чате без
Go-сборки. Плагин добавляет нативную панель, но к готовности системы отношения
не имеет.

**Этап 0 — на OCaml, без Docker.** Сборка через nix, как в `math-coding`:
`buildDunePackage` даёт бинарник без интерпретатора, `systemd` запускает его
напрямую, контейнеры не нужны — хост уже NixOS, Postgres общий. Alembic в
проекте нет: мигратор свой, идемпотентные SQL-файлы с номером плюс таблица
`schema_version`. Первый компилируемый результат этапа 0 — не «каркас», а
работающая пара «мигратор → схема → `/healthz`»: она доказывает, что
OCaml-тулчейн, `caqti` и Nix-деплой сходятся, до того как появится доменная
логика.

#### Факт на 18.11.2026: этап 0 закрыт

Проверено, а не заявлено:

| Проверка | Результат |
|---|---|
| `dune build --root .` | без ошибок, предупреждение 8 включено как ошибка (`-w +8 -warn-error +8`) |
| `dune runtest --root .` | 26 тестов OK: домен — 17 (машина состояний, R1/R3), идентичность — 9 (нормализация, resolve) |
| `nix build .#doska` | успешно, checkPhase с тестами проходит; артефакт в nix store |
| `doska migrate --db-url postgresql:///doska` | применён `001_init.sql`; повторный запуск — «нечего применять» |
| Схема в БД | 11 доменных таблиц + `schema_version`, расширения `citext` и `pg_trgm` |
| `doska health --db-url postgresql:///doska` | `ok` |
| `doska serve` + `/healthz` | 200 `{"status":"ok"}`; `/version`, `/` отвечают |

Что осталось на этапе 0 незакрытым: NixOS-модуль `services.doska.*` в
AngaraConfig, systemd-юнит, vhost в Caddy и фронтенд (этап 5). Пока сервер
слушает `localhost` (только `::1`), внешний доступ закрыт — это осознанно:
деплой идёт после этапа 1.

#### Факт на 18.11.2026: этап 1 — схема и API (первый срез)

Проверено, а не заявлено:

| Проверка | Результат |
|---|---|
| `dune build --root .` | без ошибок; в проекте любое предупреждение компилятора — ошибка сборки |
| `dune runtest --root .` | 46 тестов OK: домен — 17, идентичность — 9, репозитории — 7 (живая БД), API — 13 (живая БД) |
| `dune exec --root . test/api_test.exe` | 13/13: запрещённый переход — 403 с деталями, а не 500; без актора — 401; неизвестный статус — 400; устаревшая версия — 409; повторное создание — 200 с `idempotent`; список пагинирован курсором |
| `dune exec --root . test/repo_test.exe` | 7/7: задача сохраняется и читается обратно, `version` защищает смену статуса, комментарии и evidence сохраняются, событие попадает в журнал, фильтры и пагинация отбирают нужное |
| `doska migrate --migrations-dir migrations` | применён `002_task_ref_seq.sql`: последовательность `task_ref_seq` и уникальный индекс на `(source, source_ref)`; `001_init.sql` не менялся |
| Отрицательные control'ы | четыре control'а из `test/break/` роняют ровно свой verifier: запрет правила → 500, курсор страницы теряется, дедупликация ломается, версия не растёт |

Что на этапе 1 ещё не закрыто:

- **Идентификация — временная.** Актора задаёт заголовок `X-Doska-Actor`
  (логин), администраторы — `DOSKA_ADMIN_HANDLES`. Это не аутентификация: сервер
  доверяет заголовку и годится только в доверенной сети. Токены, таблица
  `credential` и хеширование — этап 4 (см. таблицу §11).
- **Назначение — правило API, а не домена.** Агент не может назначить задачу
  другому, человек может. На этапе 2 правило переедет в домен.
- **REST покрыт не полностью.** Сделаны задачи (создание, чтение, список,
  правка, переход, назначение, комментарий, evidence), `activity`, `actors`.
  Не сделаны связи между задачами (§3.5), поиск по evidence и `verification`
  (§3.4), outbox-доставка уведомлений (§3.8), realtime (§6.5).
- **Пагинация — курсорная** (keyset) по `created_at DESC, id DESC`: `limit` по
  умолчанию 50, максимум 200. `/tasks/mine` не сделан.
- **Web, MCP, Mattermost, импорт из Teamboard** — этапы 4–6 и 8, вне этапа 1.

Решения, принятые в этом срезе:

- SQL собирается из прошедших валидацию значений и экранируется существующим
  `Conn.quote` — новой зависимости ради параметризации не заводили.
- Строки читаются как JSON (`row_to_json(...)::text`), разбор — в одном месте
  (`src/db/row.ml`).
- Смена статуса и запись в `activity` идут в одной транзакции.
- Тесты живут на настоящей базе: без `DOSKA_DATABASE_URL` они падают с понятным
  сообщением, а не «проходят мимо».

**Расхождение с таблицей этапов закрыто решением владельца от 18.11.2026.**
В таблице §11 этап 1 теперь значит «временная идентификация по заголовку», а
токены, таблица `credential` и хеширование перенесены в этап 4 — там, где
появляются учётки агентов. Идентичность этапа 2 — это алиасы и резолвер, а не
аутентификация.

#### Факт на 18.11.2026: этап 2 — идентичность (первый срез)

Проверено, а не заявлено:

| Проверка | Результат |
|---|---|
| `dune build --root .` | без ошибок; в проекте любое предупреждение компилятора — ошибка сборки |
| `dune runtest --root .` | 78 тестов OK: домен — 17, типы домена — 8, идентичность (без БД) — 9, репозитории — 13, идентичность на БД — 10, API — 21 |
| `doska import --source mattermost` | пользователей 23 (людей 13, агентов 10); алиасов 42. Повторный прогон: создано 0, обновлено 23 — импорт идемпотентен |
| `migrations/003_actor_source.sql` | применён: `actor.source`, `actor.source_ref`, частичный уникальный индекс `actor_source_ref_uniq`; повторный запуск мигратора — «нечего применять» |
| `POST /api/v1/actors/resolve` по 97 строкам `annotations.json` | 97/97 ответов: 52 непустых owner разрешены — 27 в настоящих актёров (`legist` → «Юрист», `Пётр` → «Пётр Косов»), 25 в заглушки (6 различных: `az`, `yaz`, `human:operator`, `upstream getpaseo/paseo`, `администратор сервера`, `владелец платформы`); 45 пустых owner — 400 «имя пустое» |
| Отрицательные control'ы | девять новых control'ов из `test/break/` роняют ровно свой verifier кодом 1: уникальность ключа источника, составной ключ, идемпотентность алиаса, признак заглушки, копирование алиаса, маршрут `/actors/resolve`, различатель «человек/агент», идемпотентность импорта, алиас по имени без фамилии |

Решения, принятые в этом срезе:

- **Пустое имя — 400, а не заглушка.** Пустой `owner` в annotations означает
  «владелец неизвестен», а не «человек по имени ""». Заглушка на пустое имя
  засоряла бы базу вымышленным человеком.
- **Различатель «человек / агент» — должность или служебный адрес.** Правило
  «`position` непустое ⇒ агент» на живой базе неверно: у `calls` и `system-bot`
  должность пуста. Признак агента — непустая должность **или** почта в домене
  `@localhost` (§5.3).
- **Алиас по имени без фамилии.** Без него «Пётр» не разрешился бы в
  «Пётр Косов»: §5.2 сравнивает полное отображаемое имя.
- **Ключ актёра — пара `(source, source_ref)`.** Импорт идемпотентен, а
  заглушка, созданная резолвером, при импорте превращается в настоящего
  актёра: тот же `id`, алиасы остаются в силе.
- **Токен Mattermost не попадает в код и в список процессов.** HTTP-запрос
  уходит в `curl`, конфигурация с заголовком авторизации передаётся через
  stdin; секрет приходит из окружения (`DOSKA_MATTERMOST_TOKEN`).

Что на этапе 2 ещё не закрыто:

- **Аутентификации нет.** Идентификация — по заголовку `X-Doska-Actor`
  (см. §11, этап 1); токены и `credential` — этап 4.
- **Заглушки не связаны с людьми.** Шесть имён из annotations ждут владельца;
  связывание — ручная операция администратора.
- **Git- и email-пространства имён пусты.** Только `mattermost`; импорт
  git-конфигов — этап 3.
- **MCP, веб, Mattermost-плагин** — этапы 4–6 и 8.

#### Факт на 20.11.2026: сервисный слой (D5)

Первый срез по D5: use case'ы задач уехали из HTTP-обработчика в
`src/service/task.ml`, REST стал тонким адаптером.

Проверено, а не заявлено:

| Проверка | Результат |
|---|---|
| `dune build --root .` | без ошибок; сервисный слой собирается вместе с доменом и API |
| `dune runtest --root .` | 87 тестов OK: восемь новых — на сервисный слой, девятый — на разбор интерфейса в домене |
| `test/check_service_layer.sh` | в `src/api/tasks.ml` нет ни `Rules.check`, ни `Rules.may_assign`, ни прямых вызовов `Db.Repo_task.*`; в `src/service/task.ml` — и то и другое |
| `mathc run` | verdict: green; 38 claim'ов `holds (current)`, 38 `negative control proven`, `uncovered: 0 file(s)` |
| Отрицательные control'ы | шесть новых control'ов из `test/break/` роняют свой verifier кодом 1: правило переехало в HTTP, интерфейс в журнале заменён константой, назначение другому разрешено, ошибка хранилища стала запретом, правка выдаёт себя за смену статуса, набор интерфейсов в домене и в базе разошёлся |

Решения, принятые в этом срезе:

- **Одно правило — одна реализация.** Правило перехода и правило назначения
  живут в домене (`src/domain/rules.ml`) и вызываются сервисом. HTTP-слой
  их не дублирует: иначе MCP и CLI разойдутся с REST на второй же правке.
- **Интерфейс — часть данных, а не строковая константа.** Поле
  `activity.interface` хранит закрытый тип `Interface.t`
  (`api | mcp | cli | web | mattermost | paseo | import | system`), а не
  произвольную строку. Метрика внедрения из §12 («какой интерфейс создаёт
  задачи») становится проверяемой: неизвестное значение читается как
  `system`, а не молча теряется. Набор значений ограничен и в самой базе
  (`activity_interface_check`, миграция `005_activity_interface_check.sql`).
- **Отказ — значение, а не исключение.** `Service.Failure` — закрытый тип
  (`bad_request | forbidden | not_found | conflict | storage`), HTTP-ответ
  получается из него одной функцией `Errors.of_failure`. Ошибка хранилища
  (`storage`) не выглядит как запрет правила (`forbidden`) — разные статусы
  и разные причины отказа.
- **Журнал помнит, что именно изменилось.** Правка задачи пишет в журнал
  `updated` со сводкой «изменены поля: title, priority», а не выдаёт себя за
  смену статуса. Для этого в домен добавлен вариант `Activity.Updated`, в
  базе — значение `updated` в `activity_action` (миграция
  `004_activity_action_updated.sql`).
- **Идентичность администратора — не API.** Проверка `is_admin` и список
  `DOSKA_ADMIN_HANDLES` переехали в `src/identity/admin.ml`: сервис не имеет
  права зависеть от HTTP-слоя.

Что в этом срезе не закрыто:

- **Правила переходов всё ещё в коде, а не в базе** (§3.9) — это D6,
  отдельным шагом.
- **Сервисный слой покрывает только задачи.** Актёры, проекты, доказательства
  и импорт по-прежнему читаются из HTTP-слоя напрямую.
- **Тексты ошибок про «этап 2» устарели.** `may_assign` унаследовал формулировку
  из api-слоя; переформулируется вместе с `credential.can_assign` на этапе 4.

#### Факт на 20.11.2026: главный запрос (`/tasks/mine`)

Второй срез по §6.1: `GET /tasks/mine` — то, ради которого трекер затевался.
Задачи исполнителя по всем проектам, отсортированные по срочности.

Проверено, а не заявлено:

| Проверка | Результат |
|---|---|
| `dune build --root .` | без ошибок |
| `dune runtest --root .` | 93 теста OK: шесть новых — на главный запрос |
| `mathc run` | verdict: green; 43 claim'а `holds (current)`, 43 `negative control proven`, `uncovered: 0 file(s)` |
| Отрицательные control'ы | пять новых control'ов из `test/break/` роняют свой verifier кодом 1: чужой исполнитель попадает в выборку, порядок переставлен, закрытая задача попадает в выборку, страницы повторяют строку, маршрут `/tasks/mine` перехватывается `/tasks/:ref` |

Решения, принятые в этом срезе:

- **«Мои» — это исполнитель, и он приходит из заголовка актора.**
  Клиент не подставляет логин в тело запроса: иначе «мои задачи» означали бы
  «задачи, которые я назвал». Фильтра по проекту нет — главный запрос
  показывает работу исполнителя целиком.
- **Открытость задачи — три признака, а не один.** `deleted_at IS NULL`,
  `completed_at IS NULL` и `status NOT IN ('done','cancelled')`. Задача,
  принятая переходом в `done`, и задача, отменённая, в главный запрос не
  попадают — как и задача, удалённая в мягкую корзину.
- **Порядок — по срочности, четырьмя корзинами.** Просроченные первыми, потом
  срок в ближайшие сутки, потом остальные, потом без срока; внутри корзины —
  срок, приоритет, давность и идентификатор. Идентификатор в конце нужен
  для полного порядка: без него равные строки переставлялись бы между
  страницами.
- **`COALESCE(due_at, 'infinity')` вместо `NULLS LAST`.** В сравнении
  кортежей Postgres даёт для NULL «неизвестно», а не «больше»: с чистым
  `due_at` задачи без срока нельзя было бы расставить между собой, и
  курсорная пагинация по ключу порядка была бы некорректной. Порядок тот
  же, сравнение — рабочее.
- **Курсор — идентификатор последней задачи страницы.** Неверный курсор
  (не uuid) игнорируется, курсор на несуществующую задачу даёт пустую
  страницу. Ошибка в курсоре — не ошибка запроса: клиент с битым курсором
  получает первую страницу, а не 400.
- **Маршрут `/tasks/mine` стоит раньше `/tasks/:ref`.** `Dream` проверяет
  маршруты по порядку списка, иначе параметризованный маршрут перехватил бы
  `mine` и запрос ушёл бы в чтение задачи по референсу.

Что в этом срезе не закрыто:

- **Главный запрос не видит иерархию.** Задачи выдаются плоским списком;
  связи между задачами (`links`, `parent_id`) в выборку не входят.
- **Группировки нет.** `GET /tasks/mine` отдаёт один список; MCP-инструмент
  `my_tasks` обещает сгруппированный вид — это отдельная работа.
- **`/overview` не сделан.** Сводка (WIP, застрявшие, по людям) — следующий
  пункт §6.1.
- **Задачи без срока не отличить от «очень поздних».** Корзина 3 означает
  «срока нет», а не «срок сильно позже»; в интерфейсе это придётся
  показывать явно.

#### Факт на 21.11.2026: заявка и отпуск (claim/release)

Третий срез по §6.1: агент берёт задачу в работу и возвращает её в пул.

Проверено, а не заявлено:

| Проверка | Результат |
|---|---|
| `dune build --root .` | без ошибок |
| `dune runtest --root .` | 108 тестов OK: семь новых — на API, восемь — на сервисный слой |
| `mathc run` | verdict: green; 50 claim'ов `holds (current)`, 50 `negative control proven`, `uncovered: 0 file(s)` |
| Отрицательные control'ы | семь новых control'ов из `test/break/` роняют свой verifier кодом 1: посторонний агент отнимает назначенную задачу, заявка перебивает назначение, заявка проходит из неверного статуса, отпуск достаётся постороннему агенту, отпуск не возвращает задачу в пул, журнал заявки и журнал отпуска перепутаны |

Решения, принятые в этом срезе:

- **Отпустить может исполнитель-агент или любой человек.** Право перехода
  `in_progress → todo` — не «кто угодно», как было в общем `/transition`, а
  «исполнитель или человек»: это ровно строка §4.1 «agent (release), human».
  Общий переход для этого случая сузился тем же правилом — иначе ADR и код
  говорили бы разное, а правило, записанное дважды, разошлось бы с первой
  же правкой.
- **Заявка не отменяет назначение.** Свободную задачу заявка занимает
  (исполнитель — претендент), назначенную — не перебивает: назначение — это
  обязательство, а не подпись «времянно сдал на тебя».
- **Отпуск всегда возвращает в пул.** Исполнитель снимается
  (`assignee := NULL`), статус становится `todo`.
- **Версия обязательна.** Тело — `{version, reason?}`: без версии — 400, с
  устаревшей — 409. Оптимистичная блокировка здесь и есть механизм взаимного
  исключения двух претендентов; без неё заявка была бы гонкой.
- **Неверное состояние — 409, нарушение правила — 403.** Неверное состояние
  лечится повторным чтением, нарушение правила — нет. Разные статусы —
  разные причины отказа.
- **Миграция не понадобилась.** Значения `claimed` и `released` были в
  перечислении `activity_action` с самого первого перечисления.

Что в этом срезе не закрыто:

- **Заявка — только на себя.** `/tasks/assign` назначает на другого; claim
  занимает задачу претендентом, а не назначает её другому.
- **Очереди свободных задач нет.** `/tasks/mine` показывает то, что уже
  заявлено; «взять любую свободную задачу» как отдельный запрос не
  сделано.
- **Иерархия и связи в заявку не входят.** Claim работает с плоской задачей;
  `links` и `parent_id` — следующий пункт §6.1.
- **MCP-инструменты `claim_task` и `release_task` не реализованы.** REST-
  контракт готов, транспорт MCP — нет.

#### Слой доказательств: math-coding

Решение владельца от 18.11.2026: **разработка doska ведётся по методу
math-coding v5**. Метод не заменяет тесты и CI — он строит поверх них карту
«что подтверждено, чем и насколько независимо».

Как это устроено в проекте:

- **Источник.** Настоящий документ. Обязательства из §3–§6 становятся
  claim'ами, связанными с его digest'ом. Правка документа помечает claim'ы
  как `outdated` и требует пересмотра человеком — это защита от расхождения
  кода и замысла.
- **Цель (AIM).** «Каждое обязательство из принятой архитектуры doska
  связано с проверяемым доказательством».
- **Область (SCOPE).** `src/`, `test/`, `migrations/` — продукт, проверки и
  миграции. Вне области остаётся непроверенным, и `mathc` показывает это
  списком `uncovered`.
- **Владелец.** Peter. Человеческие решения (`waive`, `record`,
  `review-source`) фиксирует он, агент не присваивает себе человеческий
  review.

Каждое обязательство, которое уже реализовано и проверяемо, получает свой
claim' — по одному на обязательство. Перечень живой: его читает `mathc` из
`spec.json`, человеку его показывает [README](../../README.md). Здесь он не
приводится целиком: архитектурный документ меняется медленнее кода, и
перечень в нём устарел бы первым. Первый срез, этап 1 (18.11.2026) — восемь
claim'ов:

| Claim | Обязательство | Verifier |
|---|---|---|
| `r1-agent-acceptance` | D1, §4.2: агент не закрывает задачу сам, кроме `autonomy = auto` | `dune exec --root . test/domain_test.exe` |
| `identity-resolution` | §5.2: «Пётр» и варианты — один актор, нераспознанное имя не теряется | `dune exec --root . test/identity_test.exe` |
| `migration-idempotent` | §9.2: повторное применение миграции не создаёт дублей | `sh test/check_migration.sh idempotent` |
| `migration-immutable` | §9.2: применённый файл менять нельзя — мигратор сверяет контрольную сумму | `sh test/check_migration.sh immutable` |
| `api-transition-r1` | §6.1, D1: запрет правила домена — 403 с деталями, а не 500 | `dune exec --root . test/api_test.exe` |
| `api-list-pagination` | §6.1: список задач — фильтры и курсорная пагинация | `dune exec --root . test/api_test.exe` |
| `api-idempotent-create` | §3.3, §10.2: повторное создание по `(source, source_ref)` не плодит дубль | `dune exec --root . test/api_test.exe` |
| `repo-status-persistence` | §3.3: смена статуса сохраняется, `version` защищает от гонки | `dune exec --root . test/repo_test.exe` |

Второй срез, этап 2 (18.11.2026) — девять claim'ов по идентичности: уникальность
ключа источника и идемпотентность миграции `003_actor_source.sql`; поиск актёра
по паре `(source, source_ref)`; алиасы в пространствах имён; заглушки вместо
потерянного имени; копирование алиаса из чужого пространства в своё; маршрут
`/actors/resolve`; различатель «человек / агент» при импорте; идемпотентность
импорта; алиасы при импорте (логин, полное имя, имя без фамилии).

У каждого claim'а есть **отрицательный control**: он меняет предмет так, что
verifier обязан упасть. Если verifier падает и без control'а, он не проверяет
ничего — метод это показывает, а не молча считает зелёным. Control'ы лежат в
`test/break/` и правят предмет ровно в одном месте.

`mathc run` — обязательный шаг CI, а не отчёт. Зелёный вердикт относится
только к объявленным claim'ам: `uncovered` публикуется вместе с ним, иначе
«всё зелено» читается как «проверено всё».

**Чего метод не делает.** Он не проверяет требования, которых нет в
утверждениях; не заменяет ADR, тесты и CI; не даёт зелёного отчёта о том, что
не объявлено. `green` — это утверждение об объявленном, а не о программе.

---

## 12. Риски

| Риск | Вероятность | Что делаем |
|---|---|---|
| Трекер станет «ещё одним местом», куда не пойдут | высокая | П7: чтение существующих данных с первого дня + ICS + чат; метрика внедрения = `activity.interface` |
| Дублирование состояния с Teamboard | средняя | жёсткое разграничение §1; карточки доски — измерение, задачи — обязательства; общая только ссылка |
| Агенты начнут плодить задачи | средняя | `backlog` по умолчанию для агентских задач, `can_assign` по умолчанию `false`, rate limit, дедуп |
| Люди не привыкнут к новому интерфейсу | средняя | сначала `tk` и чат, веб — вторым; никаких обязательных миграций |
| Двойной источник правды по статусам карточек | низкая | карточки по git остаются в Teamboard, статус обязательства — только в трекере |
| MCP-сервер под нагрузкой агентов | низкая | один процесс, без keep-alive, лимиты; проверить на 13 параллельных агентах (урок `agent-kanban`) |
| `dream 1.0.0-alpha8` — pre-release HTTP-сервер | средняя | В estate есть альтернатива `cohttp 5.3.1`; выбор делается на этапе 0 по нужным фичам (REST + WebSocket), HTTP-слой изолирован интерфейсом, чтобы замена сервера не затронула домен |
| MCP-протокол написан руками (SDK для OCaml отсутствует) | средняя | Версия протокола фиксируется в тестах (`initialize` / `tools/list` / `tools/call`); контракт проверяется интеграционным тестом с реальным MCP-клиентом; расхождение версий — явная ошибка |
| Собственный мигратор вместо готового инструмента | средняя | Миграции — идемпотентные SQL-файлы с номером и таблицей `schema_version`; каждая применяется в транзакции; перед боевым прогоном — на копии БД |
| Медленная компиляция (в т.ч. статическая линковка) | средняя | Инкрементальная сборка в деве, полная — в CI и деплое; релизная сборка через `ocamlopt`; заранее заложено время на «холодную» сборку API |
| Малая экосистема OCaml: меньше готовых решений | высокая | Своим кодом пишем только домен (состояния, правила, идентичность); инфраструктура — на проверенных пакетах из estate; ни одной новой зависимости без проверки в пине |

---

## 13. Принятые решения

Решения владельца. D1–D3 — 16.11.2026, D4 — 19.11.2026, D5 — 20.11.2026. Они
закладываются в схему и в план без оговорок.

| # | Вопрос | Решение | Что это меняет в архитектуре |
|---|---|---|---|
| **D1** | Кто закрывает задачу агента | **Агент не закрывает сам.** Закрывает заявитель или руководитель. Для доверенных проектов — режим `autonomy='auto'` | Правило R1 в §4.2. Поле `project.autonomy` обязательно, `human_gate` по умолчанию. `in_review → done` агенту доступно только в `auto`-проектах |
| **D2** | Верхняя единица работы | **Задача = обязательство.** Ветка / PR / коммит — приложенное доказательство (`evidence`) внутри неё | `evidence` — основной мост к git. `parent_id` остаётся в схеме для явных подзадач, но не является основным способом разложить работу |
| **D3** | Начало интеграции с Mattermost | **Сначала бот-путь:** команды в чате, карточки с кнопками, DM-уведомления. Плагин Mattermost на Go — отдельным этапом позже | Этап 6 (чат) идёт раньше плагина. Go-сборка не входит в критический путь, значит первый релиз не зависит от Go-конвейера |
| **D4** | Стек веб-фронтенда | **Веб-компоненты на чистом JavaScript + D3.js.** React, Vite и TypeScript убраны. Лёгкий фреймворк допускается (первый кандидат — Lit), но не обязателен | §6.4, §9.1, §9.2. Клиент отражает функциональную модель сервера: чистые функции, неизменяемое состояние, ошибка — значение. D3.js — единственная runtime-зависимость, отвечает за визуализации. Статика отдаётся как есть, без сборщика |
| **D5** | Где живёт логика задач | **Use case'ы задач — в сервисном слое (`src/service/task.ml`).** REST, MCP и CLI — адаптеры над ним; HTTP-слой не содержит правил | §6.0, §9.1. Слои `src/domain/ → src/service/ → src/api|mcp|cli`. Правило перехода и правило назначения — в домене (`src/domain/rules.ml`), вызываются сервисом. Отказ — значение закрытого типа `Service.Failure`, HTTP-код получается из него маппингом. Журнал помнит интерфейс (`Interface.t`), поэтому «какой интерфейс создаёт задачи» — проверяемый факт, а не догадка |

**Осталось решить позже (не блокирует старт):**

- ~~**Название.**~~ **Решено 18.11.2026: проект называется `doska`.**
  Имя не прошито в схему БД — референс задачи формируется как `DSK-<номер>`.
  Плагин Mattermost, NixOS-модуль и URL-префиксы следуют за этим именем.
- **Один workspace или персональные пространства.** Заложен один общий workspace
  + разделение по `project` (12 людей, 10 агентов, 54 проекта — многопользовательская
  среда, персональные пространства избыточны). Если понадобится — добавляется
  без миграции, `workspace_id` есть в схеме как внешний ключ.

### Что из этого уже зафиксировано в DDL

```sql
-- D1: режим приёмки на уровне проекта
project.autonomy  text NOT NULL DEFAULT 'human_gate'
                  CHECK (autonomy IN ('human_gate','auto'))

-- D2: ветка/PR — доказательство, а не отдельная задача
evidence.kind  evidence_kind  -- 'branch' | 'pr' | 'commit' | ...
evidence.task_id uuid NOT NULL REFERENCES task(id) ON DELETE CASCADE

-- D3: отдельного кода для Mattermost-плагина в ядре нет;
--     интеграция идёт через outbox + webhook-приёмник бота
notification.channel  text  -- 'mattermost_dm' | 'mattermost_channel' | 'webhook'
```

D4 схемы не касается: решение про стек клиента, а не про данные.

D5 схемы касается в одном месте: журнал должен помнить интерфейс, через
который пришло действие, и отличать правку от смены статуса.

```sql
-- D5: интерфейс — закрытый тип, а не произвольная строка
activity.interface  text NOT NULL DEFAULT 'api'
                   CHECK (interface IN ('api','mcp','cli','web',
                                        'mattermost','paseo','import','system'))
                   -- ограничение добавлено миграцией 005_activity_interface_check.sql

-- D5: правка задачи — отдельное действие в журнале
activity_action  -- 'updated' добавлено миграцией 004_activity_action_updated.sql
```

---

## Приложение: что переиспользуем, а что — нет

| Актив | Путь | Вердикт |
|---|---|---|
| Принцип двух слоёв | `Teamboard/AGENTS.md:16-107` | **Берём** — основа разграничения |
| Реестр проектов | `Teamboard/data/board/registry.json` (54) | **Берём** — источник `project` |
| Суждения по карточкам | `Teamboard/data/board/annotations.json` (97) | **Берём** — источник `task` |
| Инициативы | `Teamboard/data/board/epics.json` (20/75) | **Берём** — в `decision` + связи |
| Мост stdio→HTTP для MCP | `agent-kanban/src/agent_kanban/mcp_stdio_bridge.py` | **Берём идею, код переписываем на OCaml** — редкая удачная находка (пересылка stdin/stdout без своего протокола) |
| Приёмка magic-link | `AngaraConfig/services/subroutine-auth-bridge.nix` | **Берём** как образец (не код) |
| Референс веб-стека | `agent-kanban/web` (React 19 + Vite) | **Не берём** — стек другой (решение D4), а компоненты (`div` + inline-стили) в Mattermost/Paseo всё равно не переиспользовать |
| Образец плагина Paseo | `PaseoPlugins/yeah-provider` | **Берём** как образец структуры |
| Модель актора | `subroutine` (`is_service_account`, `responsible_user_id`) | **Переосмысливаем**: единая `actor` + `supervisor_id` + алиасы |
| Схема задачи | `subroutine.task` (40 колонок) | **Переосмысливаем**: своя, с `requester_id`, `kind`, `version`, без `recurrence` в ядре |
| Мост auth-bridge | `subroutine-auth-bridge.py`, `subroutine-cookie-proxy.py` | **Берём идею**, код не нужен |
| `subroutine` целиком | — | **Удаляем** (этап 9) |
| MCP-сервер `subroutine` | `subroutine` (15 инструментов, SQLite) | **Не берём** — своя реализация на OCaml; из чужого только идея magic-link |
| `agent-kanban` целиком | `/home/az/Projects/agent-kanban` | **Не берём**, кроме stdio-моста. Причина — ADR от 16.10 |
| OCaml-проекты в estate | `ЮрАвтоматизация` (caqti, cohttp, lwt, ppx_yojson_conv), `Psylight`, `math-coding` | **Смотрим** — рабочие прецеденты сборки, структуры и тестов |
| Статическая сборка OCaml | `math-coding` (`pkgsStatic.ocamlPackages`) | **Берём как образец** — прецедент уже в estate |
| OCaml-тулчейн | `ocaml 5.3.0`, `dune_3 3.20.2`, `dream`, `cohttp`, `caqti`, `yojson`, `alcotest`, `cmdliner` | **Берём** — всё нужное есть в закреплённом пине AngaraConfig |
| MCP-SDK для OCaml | `mcp`, `mcp-server` — в nixpkgs отсутствуют | **Нет** — JSON-RPC 2.0 вручную, ~300 строк (§9.1) |
| Мигратор БД | `squash` — в nixpkgs отсутствует | **Нет** — свой мигратор на идемпотентных SQL-файлах |
