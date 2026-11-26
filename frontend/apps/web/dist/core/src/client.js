// Клиент REST API doska. Один на все поверхности: веб, плагин Paseo,
// webapp-плагин Mattermost (D4-R).
//
// Ошибки — значения, а не исключения: тот же договор, что у сервера.
// Ответ валидируется zod-схемой: сервер, изменивший форму, роняет
// валидацию на клиенте, а не портит данные молча.
import { z } from "zod";
import { apiErrorSchema, actorPageSchema, actorSchema, issuedCredentialSchema, pageSchema, taskSchema, } from "./schemas.js";
const query = (params) => {
    const parts = Object.entries(params)
        .filter(([, value]) => value !== undefined)
        .map(([key, value]) => `${key}=${encodeURIComponent(String(value))}`);
    return parts.length === 0 ? "" : `?${parts.join("&")}`;
};
export class DoskaClient {
    baseUrl;
    token;
    constructor(options) {
        this.baseUrl = options.baseUrl.replace(/\/$/, "");
        this.token = options.token;
    }
    async request(method, target, body, schema) {
        let response;
        try {
            const init = {
                method,
                headers: { authorization: `Bearer ${this.token}` },
            };
            if (body !== undefined) {
                init.body = JSON.stringify(body);
                init.headers["content-type"] =
                    "application/json";
            }
            response = await fetch(`${this.baseUrl}${target}`, init);
        }
        catch (cause) {
            return {
                ok: false,
                error: { code: "network", message: String(cause) },
            };
        }
        const text = await response.text();
        const parsed = text === "" ? {} : JSON.parse(text);
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
            return { ok: true, value: parsed };
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
    static body(fields) {
        return fields;
    }
    listTasks(filters = {}) {
        return this.request("GET", `/api/v1/tasks${query({ ...filters })}`, undefined, pageSchema(taskSchema));
    }
    myTasks(cursor, limit) {
        return this.request("GET", `/api/v1/tasks/mine${query({ cursor, limit })}`, undefined, pageSchema(taskSchema));
    }
    getTask(ref) {
        return this.request("GET", `/api/v1/tasks/${encodeURIComponent(ref)}`);
    }
    createTask(fields) {
        return this.request("POST", "/api/v1/tasks", DoskaClient.body(fields), taskSchema);
    }
    patchTask(ref, version, fields) {
        return this.request("PATCH", `/api/v1/tasks/${encodeURIComponent(ref)}`, DoskaClient.body({ ...fields, version }), taskSchema);
    }
    transitionTask(ref, to, version, extra = {}) {
        return this.request("POST", `/api/v1/tasks/${encodeURIComponent(ref)}/transition`, DoskaClient.body({ to, version, ...extra }), taskSchema);
    }
    claimTask(ref, version, reason) {
        return this.request("POST", `/api/v1/tasks/${encodeURIComponent(ref)}/claim`, DoskaClient.body(reason === undefined ? { version } : { version, reason }), taskSchema);
    }
    releaseTask(ref, version, reason) {
        return this.request("POST", `/api/v1/tasks/${encodeURIComponent(ref)}/release`, DoskaClient.body(reason === undefined ? { version } : { version, reason }), taskSchema);
    }
    assignTask(ref, assignee) {
        return this.request("POST", `/api/v1/tasks/${encodeURIComponent(ref)}/assign`, DoskaClient.body({ assignee }), taskSchema);
    }
    commentTask(ref, body) {
        return this.request("POST", `/api/v1/tasks/${encodeURIComponent(ref)}/comment`, DoskaClient.body({ body }));
    }
    addEvidence(ref, fields) {
        return this.request("POST", `/api/v1/tasks/${encodeURIComponent(ref)}/evidence`, DoskaClient.body(fields));
    }
    overview(stuckDays, limit) {
        return this.request("GET", `/api/v1/overview${query({ stuck_days: stuckDays, limit })}`);
    }
    actors(cursor, limit) {
        return this.request("GET", `/api/v1/actors${query({ cursor, limit })}`, undefined, actorPageSchema);
    }
    resolveActor(raw) {
        return this.request("POST", "/api/v1/actors/resolve", DoskaClient.body({ raw }), actorSchema);
    }
    listCredentials() {
        return this.request("GET", "/api/v1/credentials", undefined, z.array(issuedCredentialSchema.shape.credential));
    }
    issueCredential(fields) {
        return this.request("POST", "/api/v1/credentials", DoskaClient.body(fields), issuedCredentialSchema);
    }
    revokeCredential(id) {
        return this.request("DELETE", `/api/v1/credentials/${encodeURIComponent(id)}`);
    }
    projects() {
        return this.request("GET", "/api/v1/projects");
    }
}
//# sourceMappingURL=client.js.map