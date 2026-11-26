// zod-схемы ответов API: контракты валидируются на всех поверхностях
// одним кодом. Схема — зеркало handler'а: если сервер меняет форму ответа,
// валидация на клиенте падает, а не молчит.
import { z } from "zod";
import { ACTOR_KINDS, LINK_KINDS, PROJECT_AUTONOMY, TASK_KINDS, TASK_PRIORITIES, TASK_STATUSES, } from "./types.js";
const enumSchema = (values) => z.enum(values);
const nullableString = z.string().nullable();
export const actorSchema = z.object({
    id: z.string(),
    kind: enumSchema(ACTOR_KINDS),
    handle: z.string(),
    display_name: z.string(),
    supervisor_id: nullableString,
    unresolved: z.boolean(),
});
export const taskStatusSchema = enumSchema(TASK_STATUSES);
export const taskSchema = z.object({
    ref: z.string(),
    id: z.string(),
    title: z.string(),
    description: z.string(),
    status: taskStatusSchema,
    kind: enumSchema(TASK_KINDS),
    priority: enumSchema(TASK_PRIORITIES),
    project: nullableString,
    parent_id: nullableString,
    assignee_id: nullableString,
    assignee: nullableString,
    requester_id: nullableString,
    reporter_id: nullableString,
    due_at: nullableString,
    labels: z.array(z.string()),
    source: nullableString,
    source_ref: nullableString,
    blocked_reason: nullableString,
    question: nullableString,
    asked_to_id: nullableString,
    asked_to: nullableString,
    answer: nullableString,
    answered_at: nullableString,
    version: z.number().int(),
    created_at: z.string(),
    updated_at: z.string(),
    started_at: nullableString,
    completed_at: nullableString,
});
export const projectSchema = z.object({
    id: z.string(),
    key: z.string(),
    name: z.string(),
    autonomy: enumSchema(PROJECT_AUTONOMY),
});
export const linkSchema = z.object({
    id: z.string(),
    from_id: z.string(),
    to_id: z.string(),
    kind: enumSchema(LINK_KINDS),
    created_by_id: nullableString,
    created_at: z.string(),
});
export const credentialSchema = z.object({
    id: z.string(),
    actor_id: z.string(),
    title: z.string(),
    token_prefix: z.string(),
    scopes: z.array(z.string()),
    can_assign: z.boolean(),
    expires_at: nullableString,
    last_used_at: nullableString,
    revoked_at: nullableString,
    created_at: nullableString,
});
export const issuedCredentialSchema = z.object({
    credential: credentialSchema,
    token: z.string(),
});
export const apiErrorSchema = z.object({
    error: z.object({
        code: z.enum([
            "bad_request",
            "unauthorized",
            "forbidden",
            "not_found",
            "conflict",
            "internal",
        ]),
        message: z.string(),
        details: z.record(z.unknown()).optional(),
    }),
});
/** Страница: все списочные ответы API — {items, next_cursor, limit}. */
export function pageSchema(item) {
    return z.object({
        items: z.array(item),
        next_cursor: z.string().nullable(),
        limit: z.number().int(),
    });
}
export const taskPageSchema = pageSchema(taskSchema);
export const actorPageSchema = pageSchema(actorSchema);
//# sourceMappingURL=schemas.js.map