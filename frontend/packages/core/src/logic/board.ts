// Доска: колонки по статусам и допустимые переходы.
//
// Порядок колонок и набор переходов повторяют машину состояний ADR §4.1:
// доска показывает ровно те переходы, которые правила разрешают, и не
// предлагает запрещённых.

import type { Task, TaskStatus } from "../types.js";

export const BOARD_COLUMNS: TaskStatus[] = [
  "todo",
  "in_progress",
  "blocked",
  "needs_input",
  "in_review",
  "done",
];

/** Куда задача может перейти из своего статуса (ADR §4.1). */
export const ALLOWED_TRANSITIONS: Record<TaskStatus, TaskStatus[]> = {
  backlog: ["todo"],
  todo: ["in_progress", "cancelled"],
  in_progress: ["in_review", "needs_input", "blocked", "todo"],
  blocked: ["in_progress", "todo"],
  needs_input: ["in_progress"],
  in_review: ["done", "in_progress"],
  done: [],
  cancelled: [],
};

export interface BoardColumn {
  status: TaskStatus;
  tasks: Task[];
}

/** Разложить задачи по колонкам доски, сохранив порядок внутри. */
export function groupByStatus(tasks: Task[]): BoardColumn[] {
  return BOARD_COLUMNS.map((status) => ({
    status,
    tasks: tasks.filter((task) => task.status === status),
  }));
}

/** Куда можно перетащить карточку из её текущей колонки. */
export function targetsFor(status: TaskStatus): TaskStatus[] {
  return ALLOWED_TRANSITIONS[status] ?? [];
}
