// Экран «Мои задачи»: корзины срочности из ядра, русские заголовки.

import { groupByUrgency, STATUS_LABELS } from "./core/src/index.js";

const BUCKET_TITLES = {
  overdue: "Просрочено",
  today: "Сегодня",
  week: "Неделя",
  later: "Позже",
  no_deadline: "Без срока",
  waits_for_me: "Ждут меня",
};

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

export function renderMyTasks(root, { page, onOpen }) {
  const grouped = groupByUrgency(page.items);
  let html = "<h2>Мои задачи</h2>";
  for (const { bucket, tasks } of grouped) {
    if (tasks.length === 0) continue;
    html += `<h3>${BUCKET_TITLES[bucket]} — ${tasks.length}</h3><ul>`;
    for (const task of tasks) {
      const due = task.due_at === null ? "" : new Date(task.due_at).toLocaleString("ru-RU");
      html += `<li><a data-ref="${esc(task.ref)}">${esc(task.ref)}</a> — ${esc(task.title)}
        <span class="muted">${STATUS_LABELS[task.status]} · ${esc(task.priority)} · ${esc(due)}</span></li>`;
    }
    html += "</ul>";
  }
  if (page.items.length === 0) html += "<p>Открытых задач нет.</p>";
  root.innerHTML = html;
  root.querySelectorAll("a[data-ref]").forEach((link) => {
    link.onclick = () => onOpen(link.dataset.ref);
  });
}
