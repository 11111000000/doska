-- Doska: интерфейс в журнале — закрытый набор (D5).
-- Источник: docs/design/doska-architecture-2026-11-16.md, §13 (D5), §11
-- «Факт на 20.11.2026: сервисный слой (D5)».
--
-- Домен читает интерфейс как закрытый тип (src/domain/interface.ml), а в базе
-- это была произвольная строка: опечатка в имени интерфейса оставалась бы
-- незамеченной, пока кто-то не посчитает метрику внедрения по журналу.
--
-- Правила: ограничение добавляется через DO-блок (в Postgres нет
-- ALTER TABLE ... ADD CONSTRAINT IF NOT EXISTS), значения вне набора
-- приводятся к «system» до появления ограничения, файл применяется в одной
-- транзакции и идемпотентен.

UPDATE activity
   SET interface = 'system'
 WHERE interface NOT IN ('api','mcp','cli','web','mattermost','paseo','import','system');

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conname = 'activity_interface_check'
           AND conrelid = 'activity'::regclass
    ) THEN
        ALTER TABLE activity
            ADD CONSTRAINT activity_interface_check
            CHECK (interface IN ('api','mcp','cli','web',
                                  'mattermost','paseo','import','system'));
    END IF;
END $$;
