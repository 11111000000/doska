-- Doska: начальная схема.
-- Источник: docs/design/doska-architecture-2026-11-16.md, §3.
--
-- Правила: миграция идемпотентна — таблицы, индексы и расширения создаются
-- через IF NOT EXISTS, типы — через DO-блок, который гасит duplicate_object
-- (в Postgres нет CREATE TYPE IF NOT EXISTS). Файл применяется в одной
-- транзакции, номер версии и контрольная сумма фиксируются в schema_version.

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------- акторы ---

DO $$
BEGIN
    CREATE TYPE actor_kind   AS ENUM ('human','agent','service','placeholder');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
    CREATE TYPE actor_status AS ENUM ('active','inactive','archived');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS actor (
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

CREATE INDEX IF NOT EXISTS actor_supervisor_idx ON actor(supervisor_id);
CREATE INDEX IF NOT EXISTS actor_display_idx    ON actor (lower(display_name));

-- Алиасы: один и тот же человек называется по-разному в разных системах.
CREATE TABLE IF NOT EXISTS actor_alias (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id   uuid NOT NULL REFERENCES actor(id) ON DELETE CASCADE,
    alias      citext NOT NULL,
    namespace  text NOT NULL,   -- mattermost | teamboard | git | email | manual
    source_ref text,            -- откуда: annotations.json#/annotations/*/owner
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (namespace, alias)
);

CREATE INDEX IF NOT EXISTS actor_alias_alias_idx ON actor_alias(alias);

-- --------------------------------------------------------------- проекты ---

DO $$
BEGIN
    CREATE TYPE project_status AS ENUM ('active','paused','archived');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS project (
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
    created_at     timestamptz   NOT NULL DEFAULT now(),
    updated_at     timestamptz   NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------- задачи ---

DO $$
BEGIN
    CREATE TYPE task_kind     AS ENUM ('task','bug','feature','chore','decision',
                                       'research','question','spike','risk');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
    CREATE TYPE task_status   AS ENUM ('backlog','todo','in_progress','blocked',
                                       'needs_input','in_review','done','cancelled');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
    CREATE TYPE task_priority AS ENUM ('p0','p1','p2','p3');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS task (
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

CREATE INDEX IF NOT EXISTS task_assignee_open_idx ON task(assignee_id, due_at)
    WHERE completed_at IS NULL AND status NOT IN ('done','cancelled');
CREATE INDEX IF NOT EXISTS task_project_status_idx ON task(project_id, status)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS task_due_idx           ON task(due_at)
    WHERE completed_at IS NULL AND status NOT IN ('done','cancelled');
CREATE INDEX IF NOT EXISTS task_labels_idx        ON task USING gin(labels);
CREATE INDEX IF NOT EXISTS task_meta_idx          ON task USING gin(meta);
CREATE INDEX IF NOT EXISTS task_title_trgm_idx    ON task USING gin(title gin_trgm_ops);

-- ------------------------------------------------------------ доказательства ---

DO $$
BEGIN
    CREATE TYPE evidence_kind AS ENUM ('commit','branch','pr','file','url','doc',
                                       'note','review','test');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS evidence (
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

CREATE INDEX IF NOT EXISTS evidence_task_idx ON evidence(task_id, created_at);

-- ----------------------------------------------------------------- связи ---

DO $$
BEGIN
    CREATE TYPE link_kind AS ENUM ('blocks','blocked_by','relates_to','duplicates',
                                   'implements','split_from','follows_up');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS task_link (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    from_id       uuid NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    to_id         uuid NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    kind          link_kind NOT NULL,
    created_by_id uuid REFERENCES actor(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (from_id, to_id, kind),
    CHECK (from_id <> to_id)
);

-- ----------------------------------------------------- комментарии и журнал ---

CREATE TABLE IF NOT EXISTS comment (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id    uuid NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    parent_id  uuid REFERENCES comment(id) ON DELETE CASCADE,
    author_id  uuid REFERENCES actor(id) ON DELETE SET NULL,
    body       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    edited_at  timestamptz
);

CREATE INDEX IF NOT EXISTS comment_task_idx ON comment(task_id, created_at);

DO $$
BEGIN
    CREATE TYPE activity_action AS ENUM
      ('created','status_changed','assigned','unassigned','reassigned','commented',
       'evidence_added','due_changed','priority_changed','linked','unlinked',
       'review_requested','accepted','rejected','claimed','released','cancelled',
       'deleted','restored');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS activity (
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

CREATE INDEX IF NOT EXISTS activity_task_idx    ON activity(task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS activity_created_idx ON activity(created_at DESC);
CREATE INDEX IF NOT EXISTS activity_actor_idx   ON activity(actor_id, created_at DESC);

-- ------------------------------------------------------ учётные записи агентов ---

CREATE TABLE IF NOT EXISTS credential (
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

CREATE INDEX IF NOT EXISTS credential_actor_idx  ON credential(actor_id);
CREATE INDEX IF NOT EXISTS credential_prefix_idx ON credential(token_prefix);

-- --------------------------------------------------------- outbox уведомлений ---

CREATE TABLE IF NOT EXISTS notification (
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

CREATE INDEX IF NOT EXISTS notification_pending_idx ON notification(created_at)
    WHERE delivery_state = 'pending';

-- --------------------------------------------------- правила переходов в базе ---

CREATE TABLE IF NOT EXISTS status_rule (
    kind        text NOT NULL DEFAULT 'task',
    from_status task_status NOT NULL,
    to_status   task_status NOT NULL,
    actor_kinds actor_kind[] NOT NULL,   -- кому разрешён переход
    requires    text[] NOT NULL DEFAULT '{}',
    description text,
    PRIMARY KEY (kind, from_status, to_status)
);
