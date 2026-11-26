import { defineSettings } from "@getpaseo/plugin";
import { z } from "zod";

export const doskaSettings = defineSettings({
  id: "doska",
  scope: "host",
  version: 1,
  schema: z.object({
    token: z.string(),
    baseUrl: z.string().default("http://127.0.0.1:8560"),
  }),
});
