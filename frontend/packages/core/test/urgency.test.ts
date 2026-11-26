// Группировка по срочности: корзины повторяют главный запрос ADR §6.1.

import test from "node:test";
import assert from "node:assert/strict";
import { bucketOf, groupByUrgency } from "../src/logic/urgency.js";
import type { Task } from "../src/types.js";

const NOW = new Date("2026-11-26T12:00:00Z");

const task = (fields: Partial<Task>): Task => ({
  ref: "DSK-1",
  id: "u1",
  title: "задача",
  description: "",
  status: "in_progress",
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
  created_at: "2026-11-20T00:00:00Z",
  updated_at: "2026-11-20T00:00:00Z",
  started_at: null,
  completed_at: null,
  ...fields,
});

test("просроченная, сегодняшняя и без срока попадают в свои корзины", () => {
  const overdue = task({ ref: "DSK-1", due_at: "2026-11-20T00:00:00Z" });
  const today = task({ ref: "DSK-2", due_at: "2026-11-26T18:00:00Z" });
  const week = task({ ref: "DSK-3", due_at: "2026-11-30T00:00:00Z" });
  const later = task({ ref: "DSK-4", due_at: "2026-12-20T00:00:00Z" });
  const undated = task({ ref: "DSK-5", due_at: null });
  const waiting = task({
    ref: "DSK-6",
    status: "needs_input",
    due_at: "2026-11-20T00:00:00Z",
  });
  const grouped = groupByUrgency(
    [undated, later, waiting, today, week, overdue],
    NOW,
  );
  const buckets = Object.fromEntries(grouped.map((b) => [b.bucket, b.tasks.map((t) => t.ref)]));
  assert.deepEqual(buckets, {
    overdue: ["DSK-1"],
    today: ["DSK-2"],
    week: ["DSK-3"],
    later: ["DSK-4"],
    no_deadline: ["DSK-5"],
    waits_for_me: ["DSK-6"],
  });
});

test("закрытая задача не попадает ни в одну корзину", () => {
  const done = task({ ref: "DSK-7", status: "done", due_at: "2026-11-20T00:00:00Z" });
  assert.equal(bucketOf(done, NOW), "overdue");
  const grouped = groupByUrgency([done], NOW);
  assert.equal(grouped.every((b) => b.tasks.length === 0), true);
});

test("внутри корзины порядок: срок, приоритет, давность", () => {
  const first = task({ ref: "DSK-8", priority: "p1", due_at: "2026-11-29T00:00:00Z" });
  const second = task({ ref: "DSK-9", priority: "p2", due_at: "2026-11-29T00:00:00Z" });
  const grouped = groupByUrgency([second, first], NOW);
  const week = grouped.find((b) => b.bucket === "week");
  assert.deepEqual(week?.tasks.map((t) => t.ref), ["DSK-8", "DSK-9"]);
});
