import type { Credential, IssuedCredential, Page, Project, Task, TaskDetails } from "./types.js";
export type Result<T> = {
    ok: true;
    value: T;
} | {
    ok: false;
    error: ApiError;
};
export interface ApiError {
    code: string;
    message: string;
    details?: Record<string, unknown> | undefined;
}
export interface DoskaClientOptions {
    baseUrl: string;
    /** Bearer-токен агента: выдаёт POST /api/v1/credentials. */
    token: string;
}
export interface TaskFilters {
    project?: string;
    assignee?: string;
    status?: string;
    kind?: string;
    due?: string;
    label?: string;
    q?: string;
    cursor?: string;
    limit?: number;
}
export declare class DoskaClient {
    readonly baseUrl: string;
    private readonly token;
    constructor(options: DoskaClientOptions);
    private request;
    private static body;
    listTasks(filters?: TaskFilters): Promise<Result<Page<Task>>>;
    myTasks(cursor?: string, limit?: number): Promise<Result<Page<Task>>>;
    getTask(ref: string): Promise<Result<TaskDetails>>;
    createTask(fields: Record<string, unknown>): Promise<Result<Task>>;
    patchTask(ref: string, version: number, fields: Record<string, unknown>): Promise<Result<Task>>;
    transitionTask(ref: string, to: string, version: number, extra?: {
        reason?: string;
        asked_to?: string;
        answer?: string;
    }): Promise<Result<Task>>;
    claimTask(ref: string, version: number, reason?: string): Promise<Result<Task>>;
    releaseTask(ref: string, version: number, reason?: string): Promise<Result<Task>>;
    assignTask(ref: string, assignee: string): Promise<Result<Task>>;
    commentTask(ref: string, body: string): Promise<Result<unknown>>;
    addEvidence(ref: string, fields: Record<string, unknown>): Promise<Result<unknown>>;
    overview(stuckDays?: number, limit?: number): Promise<Result<unknown>>;
    actors(cursor?: string, limit?: number): Promise<Result<Page<unknown>>>;
    resolveActor(raw: string): Promise<Result<unknown>>;
    listCredentials(): Promise<Result<Credential[]>>;
    issueCredential(fields: {
        title: string;
        scopes?: string[];
        can_assign?: boolean;
        expires_at?: string;
    }): Promise<Result<IssuedCredential>>;
    revokeCredential(id: string): Promise<Result<void>>;
    projects(): Promise<Result<Project[]>>;
}
//# sourceMappingURL=client.d.ts.map