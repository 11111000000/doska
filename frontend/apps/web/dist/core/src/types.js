// Типы ответов API doska — зеркало JSON-вида (src/api/view.ml).
//
// Зеркало держится руками: tsc не видит OCaml. Сверка типов с доменом —
// часть зелёного гейта волны 1: если сервер меняет форму ответа, зеркала
// правятся тем же коммитом.
export const ACTOR_KINDS = ["human", "agent", "service", "placeholder"];
export const TASK_STATUSES = [
    "backlog",
    "todo",
    "in_progress",
    "blocked",
    "needs_input",
    "in_review",
    "done",
    "cancelled",
];
/** Задача ещё не закрыта — попадает в «мои задачи» и в отчёты. */
export function is_open(status) {
    return status !== "done" && status !== "cancelled";
}
/** Статусы, в которых задача ждёт человека. */
export function waits_for_human(status) {
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
];
export const TASK_PRIORITIES = ["p0", "p1", "p2", "p3"];
export const PROJECT_AUTONOMY = ["human_gate", "auto"];
export const LINK_KINDS = [
    "blocks",
    "blocked_by",
    "relates_to",
    "duplicates",
    "implements",
    "split_from",
    "follows_up",
];
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
];
//# sourceMappingURL=types.js.map