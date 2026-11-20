-- Doska: источник актёра.
-- Источник: docs/design/doska-architecture-2026-11-16.md, §10.2 (каждый импорт
-- имеет source + source_ref — уникальный ключ источника) и §5.3 (наполнение
-- актёрами из Mattermost).
--
-- Правила: миграция идемпотентна — колонки добавляются через IF NOT EXISTS,
-- индексы — через IF NOT EXISTS. Файл применяется в одной транзакции, номер
-- версии и контрольная сумма фиксируются в schema_version.

ALTER TABLE actor ADD COLUMN IF NOT EXISTS source     text;
ALTER TABLE actor ADD COLUMN IF NOT EXISTS source_ref text;

COMMENT ON COLUMN actor.source IS 'Источник актёра: mattermost | manual | ...';
COMMENT ON COLUMN actor.source_ref IS 'Ключ источника: id пользователя Mattermost';

-- Один внешний объект — одна строка. Индекс частичный: у актёров, созданных
-- вручную, источника нет, и в уникальность они не попадают.
CREATE UNIQUE INDEX IF NOT EXISTS actor_source_ref_uniq
    ON actor (source, source_ref)
    WHERE source IS NOT NULL AND source_ref IS NOT NULL;

CREATE INDEX IF NOT EXISTS actor_source_idx ON actor (source);
