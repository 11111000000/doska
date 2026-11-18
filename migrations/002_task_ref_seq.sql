-- Doska: этап 1 — референс задачи и защита от дублей.
-- Источник: docs/design/doska-architecture-2026-11-16.md, §3.3 и §8.
--
-- Номера задач выдаёт последовательность: референс DSK-<номер> не
-- переиспользуется, даже если задачу удалили, — ссылки в чате остаются
-- рабочими.
--
-- Уникальный индекс по (source, source_ref) делает повторный импорт
-- идемпотентным: та же ссылка на источник не создаёт вторую задачу.

CREATE SEQUENCE IF NOT EXISTS task_ref_seq;

CREATE UNIQUE INDEX IF NOT EXISTS task_source_ref_uniq
    ON task (source, source_ref)
    WHERE source IS NOT NULL AND source_ref IS NOT NULL;
