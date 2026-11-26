import { useState } from "react";
import { useRpc, useSettings } from "@getpaseo/plugin/client";
import { Button, Text, View, TextInput } from "react-native";
import { claimRpc, myTasksRpc } from "../shared/doska-rpc.js";
import { doskaSettings } from "../shared/doska-settings.js";

const STATUS_RU: Record<string, string> = {
  backlog: "Бэклог",
  todo: "К работе",
  in_progress: "В работе",
  blocked: "Заблокирована",
  needs_input: "Ждёт ответа",
  in_review: "На приёмке",
  done: "Готово",
  cancelled: "Отменена",
};

export function TasksScreen() {
  const settings = useSettings(doskaSettings);
  const [token, setToken] = useState("");

  if (settings.status === "loading") {
    return (
      <View>
        <Text>настройки загружаются…</Text>
      </View>
    );
  }

  if (settings.status === "error" || settings.status === "invalid") {
    return <View><Text>настройки сломаны: {settings.error}</Text></View>;
  }
  const values = settings.values;
  const saveToken = () => {
    void settings.save({ token, baseUrl: values.baseUrl }, settings.revision);
  };

  if (values.token === "") {
    return (
      <View>
        <Text>Токен доступа doska (выдаёт администратор)</Text>
        <TextInput value={token} onChangeText={setToken} placeholder="dsk_…" />
        <Button title="Сохранить" onPress={saveToken} />
      </View>
    );
  }

  return <TasksList settings={values} />;
}

function TasksList({ settings }: { settings: { token: string; baseUrl: string } }) {
  const tasksQuery = useRpc(myTasksRpc);
  const [error, setError] = useState("");
  const [rows, setRows] = useState<Array<{ ref: string; title: string; status: string }>>([]);

  const load = () => {
    tasksQuery({ limit: 50 })
      .then((value) => {
        setRows(value.tasks.map((t) => ({ ref: t.ref, title: t.title, status: t.status })));
        setError("");
      })
      .catch((e: unknown) => setError(String(e)));
  };

  if (rows.length === 0 && error === "") load();

  return (
    <View>
      {error !== "" ? <Text>ошибка: {error}</Text> : null}
      {rows.map((row) => (
        <Text key={row.ref}>
          {row.ref} — {row.title} ({STATUS_RU[row.status] ?? row.status})
        </Text>
      ))}
    </View>
  );
}
