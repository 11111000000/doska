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
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT actor_handle_uniq UNIQUE (handle)
);
CREATE INDEX actor_supervisor_idx ON actor(supervisor_id);
CREATE INDEX actor_display_idx    ON actor (lower(display_name));

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
| Mattermost API | 22 активных пользователя | `position != ''` ⇒ `kind='agent'`, иначе `kind='human'`; `handle` = username; `display_name` = first+last |
| Teamboard `registry.json` | 54 проекта | `project.key` = id, `repo_path`, `asset_class` |
| Teamboard `annotations.json` | 97 суждений | → задачи (см. §7) |
| Git-конфиги | email → handle | alias namespace `git` |

Различатель «человек / агент» в Mattermost уже существует: поле `position`
непустое только у ботов (`board` → «Агент доски задач и проектов», `comrade` →
«Инженерный агент»). Это проверено по базе: у всех 12 людей `position` пуст.

---

## 6. Интерфейсы

### 6.1. REST API

```
GET    /api/v1/tasks                    ?project=&assignee=&status=&kind=
                                       &due=&q=&label=&limit=&cursor=
GET    /api/v1/tasks/mine               ← главный запрос: мои задачи по всем проектам
GET    /api/v1/tasks/{ref}
POST   /api/v1/tasks
PATCH  /api/v1/tasks/{ref}              (If-Match: version)
POST   /api/v1/tasks/{ref}/transition    {to, reason?, version}
POST   /api/v1/tasks/{ref}/claim
POST   /api/v1/tasks/{ref}/release
POST   /api/v1/tasks/{ref}/assign        {assignee}
POST   /api/v1/tasks/{ref}/comment
POST   /api/v1/tasks/{ref}/evidence
POST   /api/v1/tasks/{ref}/links
GET    /api/v1/projects
POST   /api/v1/projects
GET    /api/v1/actors
POST   /api/v1/actors/{id}/aliases
POST   /api/v1/actors/resolve            {raw} → actor
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
  t.due_at NULLS LAST,
  t.priority,
  t.created_at;
```

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

Стек: React 19 + Vite + TypeScript, тёмная тема по умолчанию. В estate уже есть
рабочий референс (`agent-kanban/web` — React 19 + Vite), но компоненты пишутся
свои: текущие используют inline-стили и `div`, в Mattermost/Paseo их не
переиспользовать.

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
| Плагин-панель (клиент, React Native) | «Мои задачи» прямо в Paseo |
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

Фронтенд остаётся **React 19 + Vite + TypeScript**. `js_of_ocaml` в nixpkgs
есть, но для доски с drag&drop, фильтрами и живыми обновлениями React
выигрывает по плотности работы; OCaml-сервер и TS-клиент общаются по REST.

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
│   └── activity.ml       события журнала
├── identity/       библиотека `identity`: normalize + resolve (алиасы → актор)
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

Фактическое состояние на 18.11.2026 — этап 0: реализованы `domain`
(`status`, `actor`, `task`, `rules`), `identity` (`resolve`), `db` (`conn`,
`migrate`), `api` (`server`), `version` и `bin/doska.ml`. Остальные каталоги
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
  Фронт — `pnpm build` в `nodejs` env, раздаётся сервисом как статика.
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
| **1. Схема и API** | actor/project/task/evidence/activity/credential, переходы, auth | тесты на переходы и на R1 (агент не закрывает сам) |
| **2. Идентичность** | импорт Mattermost, алиасы, резолвер, placeholders | 22 актора, `/actors/resolve` работает на всех строках из annotations |
| **3. Миграция** | импорт registry + annotations + epics | 97 задач, повторный импорт не создаёт дублей |
| **4. Агенты** | MCP-сервер, 16 инструментов, учётки, `doska` | агент создаёт, берёт и комментирует задачу через MCP |
| **5. Люди** | веб (мои задачи, доска, карточка), ICS-календарь | человек видит свои задачи в браузере и в календаре |
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
  `credential` и хеширование — этап 2.
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

**Расхождение с таблицей этапов решает владелец.** В §11 этап 1 включает
`credential` и `auth`, но по решению от 18.11.2026 идентификация (токены,
`credential`, хеширование) — этап 2. Таблицу §11 не правил: план этапов — не
решение агента.

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

## 13. Принятые решения (16.11.2026)

Решения владельца, зафиксированные в этот день. Они закладываются в схему и в
план без оговорок.

| # | Вопрос | Решение | Что это меняет в архитектуре |
|---|---|---|---|
| **D1** | Кто закрывает задачу агента | **Агент не закрывает сам.** Закрывает заявитель или руководитель. Для доверенных проектов — режим `autonomy='auto'` | Правило R1 в §4.2. Поле `project.autonomy` обязательно, `human_gate` по умолчанию. `in_review → done` агенту доступно только в `auto`-проектах |
| **D2** | Верхняя единица работы | **Задача = обязательство.** Ветка / PR / коммит — приложенное доказательство (`evidence`) внутри неё | `evidence` — основной мост к git. `parent_id` остаётся в схеме для явных подзадач, но не является основным способом разложить работу |
| **D3** | Начало интеграции с Mattermost | **Сначала бот-путь:** команды в чате, карточки с кнопками, DM-уведомления. Плагин Mattermost на Go — отдельным этапом позже | Этап 6 (чат) идёт раньше плагина. Go-сборка не входит в критический путь, значит первый релиз не зависит от Go-конвейера |

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
| Референс веб-стека | `agent-kanban/web` (React 19 + Vite) | **Берём** как референс стека, компоненты пишем свои |
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
