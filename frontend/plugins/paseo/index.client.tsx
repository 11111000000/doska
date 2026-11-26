import type { PluginClientContext } from "@getpaseo/plugin/client";
import { TasksScreen } from "./client/doska.js";

export default function contribute(client: PluginClientContext) {
  // Экран и кнопка обновления: панель сама перечитывает задачи.
  client.addScreen({ id: "doska-tasks", title: "Doska: мои задачи", Component: TasksScreen });
  return () => {};
}
