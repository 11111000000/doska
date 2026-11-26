// Типы ответов API doska — зеркало JSON-вида (src/api/view.ml).
//
// Зеркало держится руками: tsc не видит OCaml. Сверка типов с доменом —
// часть зелёного гейта волны 1: если сервер меняет форму ответа, зеркала
// правятся тем же коммитом.

export const ACTOR_KINDS = ["human", "agent", "service", "placeholder"] as const;
export type ActorKind = (typeof ACTOR_KINDS)[number];

export interface Actor {
  id: string;
  kind: ActorKind;
  handle: string;
  display_name: string;
  supervisor_id: string | null;
  unresolved: boolean;
}

export const TASK_STATUSES = [
  "backlog",
  "todo",
  "in_progress",
  "blocked",
  "needs_input",
  "in_review",
  "done",
  "cancelled",
] as const;
export type TaskStatus = (typeof TASK_STATUSES)[number];

/** Задача ещё не закрыта — попадает в «мои задачи» и в отчёты. */
export function is_open(status: TaskStatus): boolean {
  return status !== "done" && status !== "cancelled";
}

/** Статусы, в которых задача ждёт человека. */
export function waits_for_human(status: TaskStatus): boolean {
  return status === "needs_input";
}

export const TASK_KINDS = [
  "task",
  "bug",
  "feature",
  "chore",
  "decision",
  "research",
  "question",
  "spike",
  "risk",
] as const;
export type TaskKind = (typeof TASK_KINDS)[number];

export const TASK_PRIORITIES = ["p0", "p1", "p2", "p3"] as const;
export type TaskPriority = (typeof TASK_PRIORITIES)[number];

/** Задача в ответе API: имена полей совпадают с src/api/view.ml. */
export interface Task {
  ref: string;
  id: string;
  title: string;
  description: string;
  status: TaskStatus;
  kind: TaskKind;
  priority: TaskPriority;
  /** Ключ проекта, денормализовано: «doska», а не uuid. */
  project: string | null;
  parent_id: string | null;
  assignee_id: string | null;
  assignee: string | null;
  requester_id: string | null;
  reporter_id: string | null;
  due_at: string | null;
  labels: string[];
  source: string | null;
  source_ref: string | null;
  blocked_reason: string | null;
  question: string | null;
  asked_to_id: string | null;
  asked_to: string | null;
  answer: string | null;
  answered_at: string | null;
  version: number;
  created_at: string;
  updated_at: string;
  started_at: string | null;
  completed_at: string | null;
}

export const PROJECT_AUTONOMY = ["human_gate", "auto"] as const;
export type ProjectAutonomy = (typeof PROJECT_AUTONOMY)[number];

export interface Project {
  id: string;
  key: string;
  name: string;
  autonomy: ProjectAutonomy;
}

export const LINK_KINDS = [
  "blocks",
  "blocked_by",
  "relates_to",
  "duplicates",
  "implements",
  "split_from",
  "follows_up",
] as const;
export type LinkKind = (typeof LINK_KINDS)[number];

export interface TaskLink {
  id: string;
  from_id: string;
  to_id: string;
  kind: LinkKind;
  created_by_id: string | null;
  created_at: string;
}

export interface Credential {
  id: string;
  actor_id: string;
  title: string;
  token_prefix: string;
  scopes: string[];
  can_assign: boolean;
  expires_at: string | null;
  last_used_at: string | null;
  revoked_at: string | null;
  created_at: string | null;
}

/** Ответ на выпуск токена: секрет виден один раз. */
export interface IssuedCredential {
  credential: Credential;
  token: string;
}

/** Страница любого списочного ответа: {items, next_cursor, limit}. */
export interface Page<T> {
  items: T[];
  next_cursor: string | null;
  limit: number;
}

/** Форма ошибки API: код и сообщение, детали по желанию. */
export interface ApiErrorBody {
  error: {
    code:
      | "bad_request"
      | "unauthorized"
      | "forbidden"
      | "not_found"
      | "conflict"
      | "internal";
    message: string;
    details?: Record<string, unknown>;
  };
}

/** Карточка задачи: задача со всем, что к ней относится. */
export interface TaskDetails {
  task: Task;
  comments: unknown[];
  evidence: unknown[];
  parent: Task | null;
  children: Task[];
  links: TaskLink[];
}

/** Запись журнала активности. */
export interface Activity {
  id: string;
  actor_id: string | null;
  task_ref: string | null;
  project_key: string | null;
  action: string;
  from_value: string | null;
  to_value: string | null;
  summary: string | null;
  interface: string;
  created_at: string;
}

/** Сводка GET /overview: где застряло и кто перегружен. */
export interface Overview {
  generated_at: string;
  stuck_days: number;
  limit: number;
  totals: Record<string, number>;
  wip_by_actor: Array<{
    actor_id: string;
    handle: string;
    display_name: string;
    kind: ActorKind;
    open_tasks: number;
    in_progress: number;
    needs_input: number;
  }>;
  by_project: Array<{
    project_id: string;
    key: string;
    open_tasks: number;
  }>;
  stuck_tasks: Task[];
}

/** Действия журнала: одно множество значений с src/domain/activity.ml. */
export const ACTIVITY_ACTIONS = [
  "created",
  "status_changed",
  "questioned",
  "answered",
  "assigned",
  "unassigned",
  "reassigned",
  "commented",
  "evidence_added",
  "due_changed",
  "priority_changed",
  "linked",
  "unlinked",
  "review_requested",
  "accepted",
  "rejected",
  "claimed",
  "released",
  "cancelled",
  "deleted",
  "restored",
  "updated",
] as const;
export type ActivityAction = (typeof ACTIVITY_ACTIONS)[number];
