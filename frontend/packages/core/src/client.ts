// Клиент REST API doska. Один на все поверхности: веб, плагин Paseo,
// webapp-плагин Mattermost (D4-R).
//
// Ошибки — значения, а не исключения: тот же договор, что у сервера.
// Ответ валидируется zod-схемой: сервер, изменивший форму, роняет
// валидацию на клиенте, а не портит данные молча.

import { z } from "zod";
import {
  apiErrorSchema,
  actorPageSchema,
  actorSchema,
  issuedCredentialSchema,
  overviewSchema,
  pageSchema,
  projectSchema,
  taskPageSchema,
  taskSchema,
} from "./schemas.js";
import type {
  ApiErrorBody,
  Credential,
  IssuedCredential,
  Overview,
  Page,
  Project,
  Task,
  TaskDetails,
} from "./types.js";

export type Result<T> = { ok: true; value: T } | { ok: false; error: ApiError };

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

const query = (params: Record<string, string | number | undefined>): string => {
  const parts = Object.entries(params)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${encodeURIComponent(String(value))}`);
  return parts.length === 0 ? "" : `?${parts.join("&")}`;
};

export class DoskaClient {
  readonly baseUrl: string;
  private readonly token: string;

  constructor(options: DoskaClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/$/, "");
    this.token = options.token;
  }

  private async request<T>(
    method: string,
    target: string,
    body?: unknown,
    schema?: z.ZodType<T>,
  ): Promise<Result<T>> {
    let response: Response;
    try {
      const init: RequestInit = {
        method,
        headers: { authorization: `Bearer ${this.token}` },
      };
      if (body !== undefined) {
        init.body = JSON.stringify(body);
        (init.headers as Record<string, string>)["content-type"] =
          "application/json";
      }
      response = await fetch(`${this.baseUrl}${target}`, init);
    } catch (cause) {
      return {
        ok: false,
        error: { code: "network", message: String(cause) },
      };
    }
    const text = await response.text();
    const parsed: unknown = text === "" ? {} : JSON.parse(text);
    if (!response.ok) {
      const failure = apiErrorSchema.safeParse(parsed);
      if (failure.success) {
        return { ok: false, error: failure.data.error };
      }
      return {
        ok: false,
        error: { code: "internal", message: `HTTP ${response.status}` },
      };
    }
    if (schema === undefined) {
      return { ok: true, value: parsed as T };
    }
    const valid = schema.safeParse(parsed);
    if (!valid.success) {
      return {
        ok: false,
        error: {
          code: "contract",
          message: "ответ сервера не совпал со схемой",
          details: { issues: valid.error.issues },
        },
      };
    }
    return { ok: true, value: valid.data };
  }

  private static body(fields: Record<string, unknown>): Record<string, unknown> {
    return fields;
  }

  listTasks(filters: TaskFilters = {}): Promise<Result<Page<Task>>> {
    return this.request("GET", `/api/v1/tasks${query({ ...filters })}`, undefined, pageSchema(taskSchema));
  }

  myTasks(cursor?: string, limit?: number): Promise<Result<Page<Task>>> {
    return this.request("GET", `/api/v1/tasks/mine${query({ cursor, limit })}`, undefined, pageSchema(taskSchema));
  }

  getTask(ref: string): Promise<Result<TaskDetails>> {
    return this.request("GET", `/api/v1/tasks/${encodeURIComponent(ref)}`);
  }

  createTask(fields: Record<string, unknown>): Promise<Result<Task>> {
    return this.request("POST", "/api/v1/tasks", DoskaClient.body(fields), taskSchema);
  }

  patchTask(ref: string, version: number, fields: Record<string, unknown>): Promise<Result<Task>> {
    return this.request(
      "PATCH",
      `/api/v1/tasks/${encodeURIComponent(ref)}`,
      DoskaClient.body({ ...fields, version }),
      taskSchema,
    );
  }

  transitionTask(
    ref: string,
    to: string,
    version: number,
    extra: { reason?: string; asked_to?: string; answer?: string } = {},
  ): Promise<Result<Task>> {
    return this.request(
      "POST",
      `/api/v1/tasks/${encodeURIComponent(ref)}/transition`,
      DoskaClient.body({ to, version, ...extra }),
      taskSchema,
    );
  }

  claimTask(ref: string, version: number, reason?: string): Promise<Result<Task>> {
    return this.request(
      "POST",
      `/api/v1/tasks/${encodeURIComponent(ref)}/claim`,
      DoskaClient.body(reason === undefined ? { version } : { version, reason }),
      taskSchema,
    );
  }

  releaseTask(ref: string, version: number, reason?: string): Promise<Result<Task>> {
    return this.request(
      "POST",
      `/api/v1/tasks/${encodeURIComponent(ref)}/release`,
      DoskaClient.body(reason === undefined ? { version } : { version, reason }),
      taskSchema,
    );
  }

  assignTask(ref: string, assignee: string): Promise<Result<Task>> {
    return this.request(
      "POST",
      `/api/v1/tasks/${encodeURIComponent(ref)}/assign`,
      DoskaClient.body({ assignee }),
      taskSchema,
    );
  }

  commentTask(ref: string, body: string): Promise<Result<unknown>> {
    return this.request(
      "POST",
      `/api/v1/tasks/${encodeURIComponent(ref)}/comment`,
      DoskaClient.body({ body }),
    );
  }

  addEvidence(ref: string, fields: Record<string, unknown>): Promise<Result<unknown>> {
    return this.request(
      "POST",
      `/api/v1/tasks/${encodeURIComponent(ref)}/evidence`,
      DoskaClient.body(fields),
    );
  }

  overview(stuckDays?: number, limit?: number): Promise<Result<Overview>> {
    return this.request(
      "GET",
      `/api/v1/overview${query({ stuck_days: stuckDays, limit })}`,
      undefined,
      overviewSchema,
    );
  }

  actors(cursor?: string, limit?: number): Promise<Result<Page<unknown>>> {
    return this.request("GET", `/api/v1/actors${query({ cursor, limit })}`, undefined, actorPageSchema);
  }

  resolveActor(raw: string): Promise<Result<unknown>> {
    return this.request(
      "POST",
      "/api/v1/actors/resolve",
      DoskaClient.body({ raw }),
      actorSchema,
    );
  }

  listCredentials(): Promise<Result<Credential[]>> {
    return this.request("GET", "/api/v1/credentials", undefined, z.array(issuedCredentialSchema.shape.credential));
  }

  issueCredential(fields: { title: string; scopes?: string[]; can_assign?: boolean; expires_at?: string }): Promise<Result<IssuedCredential>> {
    return this.request("POST", "/api/v1/credentials", DoskaClient.body(fields), issuedCredentialSchema);
  }

  revokeCredential(id: string): Promise<Result<void>> {
    return this.request("DELETE", `/api/v1/credentials/${encodeURIComponent(id)}`);
  }

  projects(): Promise<Result<Project[]>> {
    return this.request("GET", "/api/v1/projects", undefined, z.array(projectSchema));
  }
}
