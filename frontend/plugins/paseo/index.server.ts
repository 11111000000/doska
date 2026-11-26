import type { PluginServerContext } from "@getpaseo/plugin/server";
import { claim, myTasks, release, requestReview } from "./server/doska.js";
import type { DoskaAuth } from "./server/doska.js";
import {
  bindAgentTaskRpc,
  claimRpc,
  myTasksRpc,
  releaseRpc,
  reviewRpc,
} from "./shared/doska-rpc.js";
import { doskaSettings } from "./shared/doska-settings.js";

const claimedByAgent = new Map<string, string>();

export default function contribute(server: PluginServerContext) {
  const settings = server.registerSettings(doskaSettings);

  const authOf = async (input: {
    token?: string;
    baseUrl?: string;
    [key: string]: unknown;
  }): Promise<DoskaAuth> => {
    const state = await settings.read();
    const fallback =
      state.status === "ready"
        ? state.values
        : { token: "", baseUrl: "http://127.0.0.1:8560" };
    return {
      token: input.token ?? fallback.token,
      baseUrl: input.baseUrl ?? fallback.baseUrl,
    };
  };

  server.handle(myTasksRpc, async (input) => {
    const auth = await authOf(input);
    const result = await myTasks(auth, input.limit);
    if (!result.ok) return { tasks: [], error: result.error };
    return { tasks: result.value.tasks };
  });

  const refHandler =
    (
      action: (
        auth: DoskaAuth,
        ref: string,
      ) => Promise<
        { ok: true; value: { text: string } } | { ok: false; error: string }
      >,
    ) =>
    async (input: { ref: string; token?: string; baseUrl?: string }) => {
      const auth = await authOf(input);
      const result = await action(auth, input.ref);
      if (!result.ok) return { text: result.error, error: result.error };
      return { text: result.value.text };
    };

  server.handle(claimRpc, refHandler(async (auth, ref) => claim(auth, ref)));
  server.handle(reviewRpc, refHandler(async (auth, ref) => requestReview(auth, ref)));
  server.handle(releaseRpc, refHandler(async (auth, ref) => release(auth, ref)));

  server.handle(bindAgentTaskRpc, async (input) => {
    claimedByAgent.set(input.agentId, input.ref);
    return { bound: true };
  });

  // Хук ADR §7.2: агент закрылся — его claim освобождается, задача
  // возвращается в пул (D2: обязательство без исполнителя не висит).
  server.on("agent.closed", async (event) => {
    const ref = claimedByAgent.get(event.agent.id);
    if (ref !== undefined) {
      claimedByAgent.delete(event.agent.id);
      const auth: DoskaAuth = {
        token: process.env.DOSKA_MCP_TOKEN ?? "",
        baseUrl: process.env.DOSKA_URL ?? "http://127.0.0.1:8560",
      };
      if (auth.token === "") return;
      const result = await release(auth, ref);
      if (!result.ok) throw new Error(result.error);
    }
  });

  return () => {};
}
