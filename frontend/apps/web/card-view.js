// Карточка задачи: поля, комментарии, действия переходов.

import { STATUS_LABELS, KIND_LABELS, PRIORITY_LABELS } from "./core/src/index.js";

const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

const NEXT = {
  backlog: ["todo"],
  todo: [],
  in_progress: ["in_review", "blocked", "needs_input"],
  blocked: ["in_progress", "todo"],
  needs_input: ["in_progress"],
  in_review: ["done", "in_progress"],
  done: [],
  cancelled: [],
};

export function renderCard(root, { details, client, onBack, onChanged, onError }) {
  const task = details.task;
  root.innerHTML = `
    <a id="back">← мои задачи</a>
    <h2>${esc(task.ref)} — ${esc(task.title)}</h2>
    <p>${esc(task.description)}</p>
    <dl>
      <dt>Статус</dt><dd>${STATUS_LABELS[task.status]}</dd>
      <dt>Вид</dt><dd>${KIND_LABELS[task.kind]}</dd>
      <dt>Приоритет</dt><dd>${PRIORITY_LABELS[task.priority]}</dd>
      <dt>Исполнитель</dt><dd>${esc(task.assignee ?? "не назначен")}</dd>
      <dt>Срок</dt><dd>${task.due_at ? esc(new Date(task.due_at).toLocaleString("ru-RU")) : "—"}</dd>
      <dt>Версия</dt><dd>${task.version}</dd>
      ${task.question ? `<dt>Вопрос</dt><dd>${esc(task.question)}</dd><dt>Ответ</dt><dd>${esc(task.answer ?? "ждёт")}</dd>` : ""}
    </dl>
    <h3>Доказательства</h3>
    <ul>${details.evidence.map((e) => `<li>${esc(e.kind)}: ${esc(e.ref_value)}</li>`).join("")}</ul>
    <h3>Комментарии</h3>
    <ul>${details.comments.map((c) => `<li>${esc(c.body)}</li>`).join("")}</ul>
    <textarea id="comment" placeholder="комментарий" rows="2" style="width:32rem"></textarea>
    <button class="primary" id="send-comment">Комментировать</button>
    <h3>Действия</h3>
    <div id="actions"></div>
    <div class="error" id="card-error"></div>
  `;
  document.getElementById("back").onclick = () => onBack();

  const actions = document.getElementById("actions");
  if (task.status === "todo") {
    const claim = document.createElement("button");
    claim.className = "primary";
    claim.textContent = "Взять в работу";
    claim.onclick = () => run(client.claimTask(task.ref, task.version));
    actions.appendChild(claim);
  }
  if (task.status === "in_progress") {
    const release = document.createElement("button");
    release.className = "danger";
    release.textContent = "Вернуть в пул";
    release.onclick = () => run(client.releaseTask(task.ref, task.version));
    actions.appendChild(release);
  }
  const next = NEXT[task.status] ?? [];
  if (next.length > 0) {
    const select = document.createElement("select");
    for (const status of next) {
      const option = document.createElement("option");
      option.value = status;
      option.textContent = STATUS_LABELS[status];
      select.appendChild(option);
    }
    const go = document.createElement("button");
    go.className = "primary";
    go.textContent = "Перевести";
    go.onclick = () => run(client.transitionTask(task.ref, select.value, task.version));
    actions.appendChild(select);
    actions.appendChild(go);
  }

  document.getElementById("send-comment").onclick = () =>
    run(client.commentTask(task.ref, document.getElementById("comment").value));

  async function run(promise) {
    const result = await promise;
    if (!result.ok) {
      document.getElementById("card-error").textContent = result.error.message;
      return;
    }
    onChanged();
  }
}
