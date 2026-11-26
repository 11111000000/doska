// Группировка «моих задач» по корзинам срочности.
//
// Порядок корзин и порядок внутри них повторяют SQL главного запроса
// (ADR §6.1): просрочено → сегодня → неделя → позже → без срока,
// внутри — срок, приоритет, давность, ref. Сервер уже отсортировал;
// клиент только раскладывает по корзинам, не пересортировывая.

import { is_open, waits_for_human, type Task, type TaskPriority } from "../types.js";

export const URGENCY_BUCKETS = [
  "overdue",
  "today",
  "week",
  "later",
  "no_deadline",
  "waits_for_me",
] as const;
export type UrgencyBucket = (typeof URGENCY_BUCKETS)[number];

export interface Bucket {
  bucket: UrgencyBucket;
  tasks: Task[];
}

const DAY_MS = 24 * 60 * 60 * 1000;

const priorityRank = (priority: TaskPriority): number =>
  ["p0", "p1", "p2", "p3"].indexOf(priority);

/** Корзина одной задачи: отметка времени — «сейчас» клиента. */
export function bucketOf(task: Task, now: Date): UrgencyBucket {
  if (waits_for_human(task.status)) return "waits_for_me";
  if (task.due_at === null) return "no_deadline";
  const due = new Date(task.due_at).getTime();
  if (Number.isNaN(due)) return "no_deadline";
  if (due < now.getTime()) return "overdue";
  if (due < now.getTime() + DAY_MS) return "today";
  if (due < now.getTime() + 7 * DAY_MS) return "week";
  return "later";
}

const compareTasks = (a: Task, b: Task): number => {
  const byDue = (a.due_at ?? "").localeCompare(b.due_at ?? "");
  if (byDue !== 0) return byDue;
  const byPriority = priorityRank(a.priority) - priorityRank(b.priority);
  if (byPriority !== 0) return byPriority;
  const byAge = a.created_at.localeCompare(b.created_at);
  if (byAge !== 0) return byAge;
  return a.ref.localeCompare(b.ref);
};

/** Разложить открытые задачи по корзинам; порядок внутри — как в SQL. */
export function groupByUrgency(tasks: Task[], now: Date = new Date()): Bucket[] {
  const grouped = new Map<UrgencyBucket, Task[]>(
    URGENCY_BUCKETS.map((bucket) => [bucket, []]),
  );
  for (const task of tasks) {
    if (!is_open(task.status)) continue;
    grouped.get(bucketOf(task, now))?.push(task);
  }
  return URGENCY_BUCKETS.map((bucket) => ({
    bucket,
    tasks: (grouped.get(bucket) ?? []).sort(compareTasks),
  }));
}
