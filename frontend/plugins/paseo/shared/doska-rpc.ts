// Контракты RPC: определения в shared — клиент и сервер говорят одним
// словарём. Токен приходит из настроек плагина (host scope): путь
// клиент → сервер локальный, один пользователь, loopback.

import { defineRpc } from "@getpaseo/plugin";
import { z } from "zod";

const taskSummary = z.object({
  ref: z.string(),
  title: z.string(),
  status: z.string(),
  priority: z.string(),
});

export const myTasksRpc = defineRpc({
  name: "doska.my_tasks",
  input: z.object({ limit: z.number().int().optional() }),
  output: z.object({ tasks: z.array(taskSummary), error: z.string().optional() }),
});

const refRpc = (name: string) =>
  defineRpc({
    name,
    input: z.object({ ref: z.string() }),
    output: z.object({ text: z.string(), error: z.string().optional() }),
  });

export const claimRpc = refRpc("doska.claim");
export const reviewRpc = refRpc("doska.request_review");
export const releaseRpc = refRpc("doska.release");

export const bindAgentTaskRpc = defineRpc({
  name: "doska.bind_agent_task",
  input: z.object({ agentId: z.string(), ref: z.string() }),
  output: z.object({ bound: z.boolean() }),
});
