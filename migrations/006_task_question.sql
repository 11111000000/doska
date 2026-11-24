-- Doska: вопрос при needs_input — адресный (R2).
-- Источник: docs/design/doska-architecture-2026-11-16.md, §4.2 (R2), §3.8.
--
-- «needs_input» — это не «застрял», а «жду конкретного ответа». Пока вопрос
-- живёт в поле note перехода, он не адресный: его не видно в карточке, и по
-- задаче непонятно, к кому идти с ответом. Поэтому задача хранит сам вопрос,
-- адресата вопроса и — когда ответили — ответ.
--
-- Правила: файл идемпотентен (колонки и значения перечисления добавляются
-- через IF NOT EXISTS), применяется целиком в одной транзакции.
--
-- CHECK-ограничения «needs_input ⇒ question IS NOT NULL» здесь нет: правило
-- держит домен, а не база. Ограничение на уровне БД потребовало бы backfill
-- существующих строк и ломало бы тестовые фикстуры, а обязательность вопроса
-- проверяет домен (src/domain/rules.ml).
--
-- Значения перечисления нужны только для записи в журнал во время работы
-- приложения: в этой же транзакции их использовать нельзя, поэтому след
-- пишется следующей транзакцией.

ALTER TABLE task ADD COLUMN IF NOT EXISTS question text;
ALTER TABLE task ADD COLUMN IF NOT EXISTS asked_to_id uuid REFERENCES actor(id) ON DELETE SET NULL;
ALTER TABLE task ADD COLUMN IF NOT EXISTS answer text;
ALTER TABLE task ADD COLUMN IF NOT EXISTS answered_at timestamptz;
ALTER TABLE task ADD COLUMN IF NOT EXISTS answered_by uuid REFERENCES actor(id) ON DELETE SET NULL;

ALTER TYPE activity_action ADD VALUE IF NOT EXISTS 'questioned';
ALTER TYPE activity_action ADD VALUE IF NOT EXISTS 'answered';
