// Схемы валидируют настоящий JSON сервера: приоритеты строчными, статус
// из домена. Ответ, не совпавший со схемой, — ошибка контракта.

import test from "node:test";
import assert from "node:assert/strict";
import { taskPageSchema } from "../src/schemas.js";

const page = {
  items: [
    {
      ref: "DSK-1",
      id: "u1",
      title: "задача",
      description: "",
      status: "todo",
      kind: "task",
      priority: "p2",
      project: "DOSKA",
      parent_id: null,
      assignee_id: null,
      assignee: null,
      requester_id: null,
      reporter_id: null,
      due_at: null,
      labels: [],
      source: "test",
      source_ref: "1",
      blocked_reason: null,
      question: null,
      asked_to_id: null,
      asked_to: null,
      answer: null,
      answered_at: null,
      version: 1,
      created_at: "2026-11-20T00:00:00Z",
      updated_at: "2026-11-20T00:00:00Z",
      started_at: null,
      completed_at: null,
    },
  ],
  next_cursor: null,
  limit: 20,
};

test("страница задач валидируется", () => {
  const result = taskPageSchema.safeParse(page);
  assert.equal(result.success, true);
});

test("приоритет не в том регистре — ошибка контракта, а не тихий пропуск", () => {
  const broken = structuredClone(page) as typeof page;
  const item = broken.items[0];
  assert.ok(item, "фикстура без задач");
  item.priority = "P2";
  assert.equal(taskPageSchema.safeParse(broken).success, false);
});

test("несуществующий статус — ошибка контракта", () => {
  const broken = structuredClone(page) as typeof page;
  const item = broken.items[0];
  assert.ok(item, "фикстура без задач");
  item.status = "paused";
  assert.equal(taskPageSchema.safeParse(broken).success, false);
});
