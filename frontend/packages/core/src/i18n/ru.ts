// Русские подписи перечислений: один словарь на все поверхности.

import type {
  LinkKind,
  ProjectAutonomy,
  TaskKind,
  TaskPriority,
  TaskStatus,
} from "../types.js";

export const STATUS_LABELS: Record<TaskStatus, string> = {
  backlog: "Бэклог",
  todo: "К работе",
  in_progress: "В работе",
  blocked: "Заблокирована",
  needs_input: "Ждёт ответа",
  in_review: "На приёмке",
  done: "Готово",
  cancelled: "Отменена",
};

export const KIND_LABELS: Record<TaskKind, string> = {
  task: "Задача",
  bug: "Дефект",
  feature: "Функция",
  chore: "Хозяйство",
  decision: "Решение",
  research: "Разведка",
  question: "Вопрос",
  spike: "Штудия",
  risk: "Риск",
};

export const PRIORITY_LABELS: Record<TaskPriority, string> = {
  p0: "P0 — сейчас",
  p1: "P1 — важно",
  p2: "P2 — обычная",
  p3: "P3 — когда-нибудь",
};

export const LINK_KIND_LABELS: Record<LinkKind, string> = {
  blocks: "мешает",
  blocked_by: "зависит от",
  relates_to: "рядом с",
  duplicates: "дублирует",
  implements: "реализует",
  split_from: "выделена из",
  follows_up: "продолжает",
};

export const AUTONOMY_LABELS: Record<ProjectAutonomy, string> = {
  human_gate: "приёмка человеком",
  auto: "агент закрывает сам",
};
