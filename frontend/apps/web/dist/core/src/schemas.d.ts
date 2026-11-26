import { z } from "zod";
export declare const actorSchema: z.ZodObject<{
    id: z.ZodString;
    kind: z.ZodEnum<["human", "agent", "service", "placeholder"]>;
    handle: z.ZodString;
    display_name: z.ZodString;
    supervisor_id: z.ZodNullable<z.ZodString>;
    unresolved: z.ZodBoolean;
}, "strip", z.ZodTypeAny, {
    id: string;
    kind: "human" | "agent" | "service" | "placeholder";
    handle: string;
    display_name: string;
    supervisor_id: string | null;
    unresolved: boolean;
}, {
    id: string;
    kind: "human" | "agent" | "service" | "placeholder";
    handle: string;
    display_name: string;
    supervisor_id: string | null;
    unresolved: boolean;
}>;
export declare const taskStatusSchema: z.ZodEnum<["backlog", "todo", "in_progress", "blocked", "needs_input", "in_review", "done", "cancelled"]>;
export declare const taskSchema: z.ZodObject<{
    ref: z.ZodString;
    id: z.ZodString;
    title: z.ZodString;
    description: z.ZodString;
    status: z.ZodEnum<["backlog", "todo", "in_progress", "blocked", "needs_input", "in_review", "done", "cancelled"]>;
    kind: z.ZodEnum<["task", "bug", "feature", "chore", "decision", "research", "question", "spike", "risk"]>;
    priority: z.ZodEnum<["p0", "p1", "p2", "p3"]>;
    project: z.ZodNullable<z.ZodString>;
    parent_id: z.ZodNullable<z.ZodString>;
    assignee_id: z.ZodNullable<z.ZodString>;
    assignee: z.ZodNullable<z.ZodString>;
    requester_id: z.ZodNullable<z.ZodString>;
    reporter_id: z.ZodNullable<z.ZodString>;
    due_at: z.ZodNullable<z.ZodString>;
    labels: z.ZodArray<z.ZodString, "many">;
    source: z.ZodNullable<z.ZodString>;
    source_ref: z.ZodNullable<z.ZodString>;
    blocked_reason: z.ZodNullable<z.ZodString>;
    question: z.ZodNullable<z.ZodString>;
    asked_to_id: z.ZodNullable<z.ZodString>;
    asked_to: z.ZodNullable<z.ZodString>;
    answer: z.ZodNullable<z.ZodString>;
    answered_at: z.ZodNullable<z.ZodString>;
    version: z.ZodNumber;
    created_at: z.ZodString;
    updated_at: z.ZodString;
    started_at: z.ZodNullable<z.ZodString>;
    completed_at: z.ZodNullable<z.ZodString>;
}, "strip", z.ZodTypeAny, {
    question: string | null;
    id: string;
    kind: "task" | "bug" | "feature" | "chore" | "decision" | "research" | "question" | "spike" | "risk";
    status: "backlog" | "todo" | "in_progress" | "blocked" | "needs_input" | "in_review" | "done" | "cancelled";
    ref: string;
    title: string;
    description: string;
    priority: "p0" | "p1" | "p2" | "p3";
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
    asked_to_id: string | null;
    asked_to: string | null;
    answer: string | null;
    answered_at: string | null;
    version: number;
    created_at: string;
    updated_at: string;
    started_at: string | null;
    completed_at: string | null;
}, {
    question: string | null;
    id: string;
    kind: "task" | "bug" | "feature" | "chore" | "decision" | "research" | "question" | "spike" | "risk";
    status: "backlog" | "todo" | "in_progress" | "blocked" | "needs_input" | "in_review" | "done" | "cancelled";
    ref: string;
    title: string;
    description: string;
    priority: "p0" | "p1" | "p2" | "p3";
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
    asked_to_id: string | null;
    asked_to: string | null;
    answer: string | null;
    answered_at: string | null;
    version: number;
    created_at: string;
    updated_at: string;
    started_at: string | null;
    completed_at: string | null;
}>;
export declare const projectSchema: z.ZodObject<{
    id: z.ZodString;
    key: z.ZodString;
    name: z.ZodString;
    autonomy: z.ZodEnum<["human_gate", "auto"]>;
}, "strip", z.ZodTypeAny, {
    id: string;
    key: string;
    name: string;
    autonomy: "human_gate" | "auto";
}, {
    id: string;
    key: string;
    name: string;
    autonomy: "human_gate" | "auto";
}>;
export declare const linkSchema: z.ZodObject<{
    id: z.ZodString;
    from_id: z.ZodString;
    to_id: z.ZodString;
    kind: z.ZodEnum<["blocks", "blocked_by", "relates_to", "duplicates", "implements", "split_from", "follows_up"]>;
    created_by_id: z.ZodNullable<z.ZodString>;
    created_at: z.ZodString;
}, "strip", z.ZodTypeAny, {
    id: string;
    kind: "blocks" | "blocked_by" | "relates_to" | "duplicates" | "implements" | "split_from" | "follows_up";
    created_at: string;
    from_id: string;
    to_id: string;
    created_by_id: string | null;
}, {
    id: string;
    kind: "blocks" | "blocked_by" | "relates_to" | "duplicates" | "implements" | "split_from" | "follows_up";
    created_at: string;
    from_id: string;
    to_id: string;
    created_by_id: string | null;
}>;
export declare const credentialSchema: z.ZodObject<{
    id: z.ZodString;
    actor_id: z.ZodString;
    title: z.ZodString;
    token_prefix: z.ZodString;
    scopes: z.ZodArray<z.ZodString, "many">;
    can_assign: z.ZodBoolean;
    expires_at: z.ZodNullable<z.ZodString>;
    last_used_at: z.ZodNullable<z.ZodString>;
    revoked_at: z.ZodNullable<z.ZodString>;
    created_at: z.ZodNullable<z.ZodString>;
}, "strip", z.ZodTypeAny, {
    id: string;
    title: string;
    created_at: string | null;
    actor_id: string;
    token_prefix: string;
    scopes: string[];
    can_assign: boolean;
    expires_at: string | null;
    last_used_at: string | null;
    revoked_at: string | null;
}, {
    id: string;
    title: string;
    created_at: string | null;
    actor_id: string;
    token_prefix: string;
    scopes: string[];
    can_assign: boolean;
    expires_at: string | null;
    last_used_at: string | null;
    revoked_at: string | null;
}>;
export declare const issuedCredentialSchema: z.ZodObject<{
    credential: z.ZodObject<{
        id: z.ZodString;
        actor_id: z.ZodString;
        title: z.ZodString;
        token_prefix: z.ZodString;
        scopes: z.ZodArray<z.ZodString, "many">;
        can_assign: z.ZodBoolean;
        expires_at: z.ZodNullable<z.ZodString>;
        last_used_at: z.ZodNullable<z.ZodString>;
        revoked_at: z.ZodNullable<z.ZodString>;
        created_at: z.ZodNullable<z.ZodString>;
    }, "strip", z.ZodTypeAny, {
        id: string;
        title: string;
        created_at: string | null;
        actor_id: string;
        token_prefix: string;
        scopes: string[];
        can_assign: boolean;
        expires_at: string | null;
        last_used_at: string | null;
        revoked_at: string | null;
    }, {
        id: string;
        title: string;
        created_at: string | null;
        actor_id: string;
        token_prefix: string;
        scopes: string[];
        can_assign: boolean;
        expires_at: string | null;
        last_used_at: string | null;
        revoked_at: string | null;
    }>;
    token: z.ZodString;
}, "strip", z.ZodTypeAny, {
    credential: {
        id: string;
        title: string;
        created_at: string | null;
        actor_id: string;
        token_prefix: string;
        scopes: string[];
        can_assign: boolean;
        expires_at: string | null;
        last_used_at: string | null;
        revoked_at: string | null;
    };
    token: string;
}, {
    credential: {
        id: string;
        title: string;
        created_at: string | null;
        actor_id: string;
        token_prefix: string;
        scopes: string[];
        can_assign: boolean;
        expires_at: string | null;
        last_used_at: string | null;
        revoked_at: string | null;
    };
    token: string;
}>;
export declare const apiErrorSchema: z.ZodObject<{
    error: z.ZodObject<{
        code: z.ZodEnum<["bad_request", "unauthorized", "forbidden", "not_found", "conflict", "internal"]>;
        message: z.ZodString;
        details: z.ZodOptional<z.ZodRecord<z.ZodString, z.ZodUnknown>>;
    }, "strip", z.ZodTypeAny, {
        code: "bad_request" | "unauthorized" | "forbidden" | "not_found" | "conflict" | "internal";
        message: string;
        details?: Record<string, unknown> | undefined;
    }, {
        code: "bad_request" | "unauthorized" | "forbidden" | "not_found" | "conflict" | "internal";
        message: string;
        details?: Record<string, unknown> | undefined;
    }>;
}, "strip", z.ZodTypeAny, {
    error: {
        code: "bad_request" | "unauthorized" | "forbidden" | "not_found" | "conflict" | "internal";
        message: string;
        details?: Record<string, unknown> | undefined;
    };
}, {
    error: {
        code: "bad_request" | "unauthorized" | "forbidden" | "not_found" | "conflict" | "internal";
        message: string;
        details?: Record<string, unknown> | undefined;
    };
}>;
/** Страница: все списочные ответы API — {items, next_cursor, limit}. */
export declare function pageSchema<T extends z.ZodTypeAny>(item: T): z.ZodObject<{
    items: z.ZodArray<T, "many">;
    next_cursor: z.ZodNullable<z.ZodString>;
    limit: z.ZodNumber;
}, "strip", z.ZodTypeAny, {
    items: T["_output"][];
    next_cursor: string | null;
    limit: number;
}, {
    items: T["_input"][];
    next_cursor: string | null;
    limit: number;
}>;
export declare const taskPageSchema: z.ZodObject<{
    items: z.ZodArray<z.ZodObject<{
        ref: z.ZodString;
        id: z.ZodString;
        title: z.ZodString;
        description: z.ZodString;
        status: z.ZodEnum<["backlog", "todo", "in_progress", "blocked", "needs_input", "in_review", "done", "cancelled"]>;
        kind: z.ZodEnum<["task", "bug", "feature", "chore", "decision", "research", "question", "spike", "risk"]>;
        priority: z.ZodEnum<["p0", "p1", "p2", "p3"]>;
        project: z.ZodNullable<z.ZodString>;
        parent_id: z.ZodNullable<z.ZodString>;
        assignee_id: z.ZodNullable<z.ZodString>;
        assignee: z.ZodNullable<z.ZodString>;
        requester_id: z.ZodNullable<z.ZodString>;
        reporter_id: z.ZodNullable<z.ZodString>;
        due_at: z.ZodNullable<z.ZodString>;
        labels: z.ZodArray<z.ZodString, "many">;
        source: z.ZodNullable<z.ZodString>;
        source_ref: z.ZodNullable<z.ZodString>;
        blocked_reason: z.ZodNullable<z.ZodString>;
        question: z.ZodNullable<z.ZodString>;
        asked_to_id: z.ZodNullable<z.ZodString>;
        asked_to: z.ZodNullable<z.ZodString>;
        answer: z.ZodNullable<z.ZodString>;
        answered_at: z.ZodNullable<z.ZodString>;
        version: z.ZodNumber;
        created_at: z.ZodString;
        updated_at: z.ZodString;
        started_at: z.ZodNullable<z.ZodString>;
        completed_at: z.ZodNullable<z.ZodString>;
    }, "strip", z.ZodTypeAny, {
        question: string | null;
        id: string;
        kind: "task" | "bug" | "feature" | "chore" | "decision" | "research" | "question" | "spike" | "risk";
        status: "backlog" | "todo" | "in_progress" | "blocked" | "needs_input" | "in_review" | "done" | "cancelled";
        ref: string;
        title: string;
        description: string;
        priority: "p0" | "p1" | "p2" | "p3";
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
        asked_to_id: string | null;
        asked_to: string | null;
        answer: string | null;
        answered_at: string | null;
        version: number;
        created_at: string;
        updated_at: string;
        started_at: string | null;
        completed_at: string | null;
    }, {
        question: string | null;
        id: string;
        kind: "task" | "bug" | "feature" | "chore" | "decision" | "research" | "question" | "spike" | "risk";
        status: "backlog" | "todo" | "in_progress" | "blocked" | "needs_input" | "in_review" | "done" | "cancelled";
        ref: string;
        title: string;
        description: string;
        priority: "p0" | "p1" | "p2" | "p3";
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
        asked_to_id: string | null;
        asked_to: string | null;
        answer: string | null;
        answered_at: string | null;
        version: number;
        created_at: string;
        updated_at: string;
        started_at: string | null;
        completed_at: string | null;
    }>, "many">;
    next_cursor: z.ZodNullable<z.ZodString>;
    limit: z.ZodNumber;
}, "strip", z.ZodTypeAny, {
    items: {
        question: string | null;
        id: string;
        kind: "task" | "bug" | "feature" | "chore" | "decision" | "research" | "question" | "spike" | "risk";
        status: "backlog" | "todo" | "in_progress" | "blocked" | "needs_input" | "in_review" | "done" | "cancelled";
        ref: string;
        title: string;
        description: string;
        priority: "p0" | "p1" | "p2" | "p3";
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
        asked_to_id: string | null;
        asked_to: string | null;
        answer: string | null;
        answered_at: string | null;
        version: number;
        created_at: string;
        updated_at: string;
        started_at: string | null;
        completed_at: string | null;
    }[];
    next_cursor: string | null;
    limit: number;
}, {
    items: {
        question: string | null;
        id: string;
        kind: "task" | "bug" | "feature" | "chore" | "decision" | "research" | "question" | "spike" | "risk";
        status: "backlog" | "todo" | "in_progress" | "blocked" | "needs_input" | "in_review" | "done" | "cancelled";
        ref: string;
        title: string;
        description: string;
        priority: "p0" | "p1" | "p2" | "p3";
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
        asked_to_id: string | null;
        asked_to: string | null;
        answer: string | null;
        answered_at: string | null;
        version: number;
        created_at: string;
        updated_at: string;
        started_at: string | null;
        completed_at: string | null;
    }[];
    next_cursor: string | null;
    limit: number;
}>;
export declare const actorPageSchema: z.ZodObject<{
    items: z.ZodArray<z.ZodObject<{
        id: z.ZodString;
        kind: z.ZodEnum<["human", "agent", "service", "placeholder"]>;
        handle: z.ZodString;
        display_name: z.ZodString;
        supervisor_id: z.ZodNullable<z.ZodString>;
        unresolved: z.ZodBoolean;
    }, "strip", z.ZodTypeAny, {
        id: string;
        kind: "human" | "agent" | "service" | "placeholder";
        handle: string;
        display_name: string;
        supervisor_id: string | null;
        unresolved: boolean;
    }, {
        id: string;
        kind: "human" | "agent" | "service" | "placeholder";
        handle: string;
        display_name: string;
        supervisor_id: string | null;
        unresolved: boolean;
    }>, "many">;
    next_cursor: z.ZodNullable<z.ZodString>;
    limit: z.ZodNumber;
}, "strip", z.ZodTypeAny, {
    items: {
        id: string;
        kind: "human" | "agent" | "service" | "placeholder";
        handle: string;
        display_name: string;
        supervisor_id: string | null;
        unresolved: boolean;
    }[];
    next_cursor: string | null;
    limit: number;
}, {
    items: {
        id: string;
        kind: "human" | "agent" | "service" | "placeholder";
        handle: string;
        display_name: string;
        supervisor_id: string | null;
        unresolved: boolean;
    }[];
    next_cursor: string | null;
    limit: number;
}>;
//# sourceMappingURL=schemas.d.ts.map