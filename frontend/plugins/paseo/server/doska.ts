// Клиент API doska для серверной части: базовый адрес и токен приходят
// из RPC-вызова (настройки плагина держит хост, путь локальный).

type Result<T> = { ok: true; value: T } | { ok: false; error: string };

export interface DoskaAuth {
  token: string;
  baseUrl: string;
}

async function api<T>(
  auth: DoskaAuth,
  method: string,
  target: string,
  schema: { parse: (v: unknown) => T },
  body?: unknown,
): Promise<Result<T>> {
  let response: Response;
  try {
    response = await fetch(`${auth.baseUrl.replace(/\/$/, "")}${target}`, {
      method,
      headers: {
        authorization: `Bearer ${auth.token}`,
        ...(body === undefined ? {} : { "content-type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  } catch (cause) {
    return { ok: false, error: `doska недоступен: ${String(cause)}` };
  }
  const text = await response.text();
  const json: unknown = text === "" ? {} : JSON.parse(text);
  if (!response.ok) {
    const err = json as { error?: { message?: string } };
    return { ok: false, error: err.error?.message ?? `HTTP ${response.status}` };
  }
  return { ok: true, value: schema.parse(json) };
}

const pageSchema = {
  parse: (v: unknown) =>
    (
      v as {
        items: Array<{ ref: string; title: string; status: string; priority: string }>;
      }
    ).items,
};

export async function myTasks(auth: DoskaAuth, limit = 20): Promise<Result<{ tasks: Array<{ ref: string; title: string; status: string; priority: string }> }>> {
  const result = await api(auth, "GET", `/api/v1/tasks/mine?limit=${limit}`, pageSchema);
  if (!result.ok) return result;
  return { ok: true, value: { tasks: result.value } };
}

async function taskVersion(auth: DoskaAuth, ref: string): Promise<number> {
  const result = await api(auth, "GET", `/api/v1/tasks/${encodeURIComponent(ref)}`, {
    parse: (v) => (v as { version: number }).version,
  });
  if (!result.ok) throw new Error(result.error);
  return result.value;
}

export async function claim(auth: DoskaAuth, ref: string): Promise<Result<{ text: string }>> {
  const version = await taskVersion(auth, ref);
  const result = await api(
    auth,
    "POST",
    `/api/v1/tasks/${encodeURIComponent(ref)}/claim`,
    { parse: (v) => v },
    { version },
  );
  if (!result.ok) return result;
  return { ok: true, value: { text: `взято в работу ${ref}` } };
}

export async function requestReview(auth: DoskaAuth, ref: string): Promise<Result<{ text: string }>> {
  const version = await taskVersion(auth, ref);
  const result = await api(
    auth,
    "POST",
    `/api/v1/tasks/${encodeURIComponent(ref)}/transition`,
    { parse: (v) => v },
    { to: "in_review", version },
  );
  if (!result.ok) return result;
  return { ok: true, value: { text: `на приёмке ${ref}` } };
}

export async function release(auth: DoskaAuth, ref: string): Promise<Result<{ text: string }>> {
  const version = await taskVersion(auth, ref);
  const result = await api(
    auth,
    "POST",
    `/api/v1/tasks/${encodeURIComponent(ref)}/release`,
    { parse: (v) => v },
    { version },
  );
  if (!result.ok) return result;
  return { ok: true, value: { text: `вернуто в пул ${ref}` } };
}
