// Доска: колонки по статусам и допустимые переходы (ADR §4.1).
// Переходы взяты из машины состояний: доска не может предложить то,
// что правила запрещают.

import test from "node:test";
import assert from "node:assert/strict";
import { ALLOWED_TRANSITIONS, BOARD_COLUMNS, groupByStatus, targetsFor } from "../src/logic/board.js";
import type { Task } from "../src/types.js";

const task = (status: Task["status"], ref: string): Task =>
  ({
    ref,
    id: ref,
    title: ref,
    description: "",
    status,
    kind: "task",
    priority: "p2",
    project: null,
    parent_id: null,
    assignee_id: null,
    assignee: null,
    requester_id: null,
    reporter_id: null,
    due_at: null,
    labels: [],
    source: null,
    source_ref: null,
    blocked_reason: null,
    question: null,
    asked_to_id: null,
    asked_to: null,
    answer: null,
    answered_at: null,
    version: 1,
    created_at: "2026-11-26T00:00:00Z",
    updated_at: "2026-11-26T00:00:00Z",
    started_at: null,
    completed_at: null,
  }) as Task;

test("колонки доски идут в порядке машины состояний", () => {
  assert.deepEqual(BOARD_COLUMNS, [
    "todo",
    "in_progress",
    "blocked",
    "needs_input",
    "in_review",
    "done",
  ]);
});

test("задачи раскладываются по своим колонкам", () => {
  const columns = groupByStatus([
    task("todo", "DSK-1"),
    task("in_progress", "DSK-2"),
    task("todo", "DSK-3"),
  ]);
  const byStatus = Object.fromEntries(columns.map((c) => [c.status, c.tasks.map((t) => t.ref)]));
  assert.deepEqual(byStatus.todo, ["DSK-1", "DSK-3"]);
  assert.deepEqual(byStatus.in_progress, ["DSK-2"]);
  assert.deepEqual(byStatus.done, []);
});

test("переходы совпадают с машиной состояний ADR §4.1", () => {
  assert.deepEqual(targetsFor("todo"), ["in_progress", "cancelled"]);
  assert.deepEqual(targetsFor("in_progress"), ["in_review", "needs_input", "blocked", "todo"]);
  assert.deepEqual(targetsFor("needs_input"), ["in_progress"]);
  assert.deepEqual(targetsFor("done"), []);
  assert.deepEqual(targetsFor("backlog"), ["todo"]);
});

test("каждый статус имеет правило переходов", () => {
  for (const status of Object.keys(ALLOWED_TRANSITIONS)) {
    assert.ok(Array.isArray(ALLOWED_TRANSITIONS[status as Task["status"]]));
  }
});
