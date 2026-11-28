// Доска проекта: колонки по статусам, перетаскивание карточек, фильтры.
//
// Перетаскивание — это переход задачи: правила и версию применяет сервер,
// доска лишь показывает допустимые цели (из общего ядра). Отказ версии (409)
// — не поломка, а чужое изменение: доска перечитывает задачи.

import {
  groupByStatus,
  targetsFor,
  STATUS_LABELS,
  PRIORITY_LABELS,
} from "./core/src/index.js";

const esc = (s) =>
  String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

const statusLabel = (status) => STATUS_LABELS[status] ?? status;

export function renderBoard(root, { client, state, onRefresh }) {
  const columns = groupByStatus(state.tasks);
  const options = state.projects
    .map((p) => `<option value="${esc(p.key)}"${p.key === state.project ? " selected" : ""}>${esc(p.name)}</option>`)
    .join("");

  root.innerHTML = `
    <h2>Доска${state.project ? ` — ${esc(state.project)}` : ""}</h2>
    <div class="board-filters">
      <select id="board-project">
        <option value="">все проекты</option>
        ${options}
      </select>
      <input id="board-assignee" placeholder="исполнитель" value="${esc(state.assignee)}" />
      <select id="board-kind">
        <option value="">любой вид</option>
        ${["task", "bug", "feature", "chore", "decision", "research", "question", "spike", "risk"]
          .map(
            (k) =>
              `<option value="${k}"${k === state.kind ? " selected" : ""}>${k}</option>`,
          )
          .join("")}
      </select>
      <button id="board-refresh">Обновить</button>
      <span id="board-message" class="error"></span>
    </div>
    <div class="board">
      ${columns
        .map(
          (column) => `
        <section class="board-column" data-status="${column.status}">
          <h3>${esc(statusLabel(column.status))} — ${column.tasks.length}</h3>
          <div class="board-cards" data-status="${column.status}">
            ${column.tasks.map((task) => cardHtml(task)).join("")}
          </div>
        </section>`,
        )
        .join("")}
    </div>`;

  const message = root.querySelector("#board-message");

  root.querySelector("#board-refresh").onclick = () => onRefresh();
  root.querySelector("#board-project").onchange = (event) => {
    state.project = event.target.value;
    onRefresh();
  };
  root.querySelector("#board-assignee").onchange = (event) => {
    state.assignee = event.target.value.trim();
    onRefresh();
  };
  root.querySelector("#board-kind").onchange = (event) => {
    state.kind = event.target.value;
    onRefresh();
  };

  root.querySelectorAll(".board-card").forEach((element) => {
    element.draggable = true;
    element.ondragstart = (event) => {
      event.dataTransfer.setData("text/plain", element.dataset.ref);
      event.dataTransfer.effectAllowed = "move";
    };
  });

  root.querySelectorAll(".board-cards").forEach((column) => {
    column.ondragover = (event) => {
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
    };
    column.ondrop = async (event) => {
      event.preventDefault();
      const ref = event.dataTransfer.getData("text/plain");
      const target = column.dataset.status;
      const task = state.tasks.find((t) => t.ref === ref);
      if (!task) return;
      const result = await client.transitionTask(ref, target, task.version);
      if (!result.ok) {
        message.textContent = `${result.error.message} — обновляю доску`;
        onRefresh();
        return;
      }
      message.textContent = "";
      onRefresh();
    };
  });
}

function cardHtml(task) {
  const due = task.due_at ? new Date(task.due_at).toLocaleString("ru-RU") : "—";
  const targets = targetsFor(task.status);
  return `
    <article class="board-card" data-ref="${esc(task.ref)}">
      <div class="board-card-ref">${esc(task.ref)}</div>
      <div class="board-card-title">${esc(task.title)}</div>
      <div class="board-card-meta">
        ${esc(task.assignee ?? "не назначен")} · ${esc(PRIORITY_LABELS[task.priority] ?? task.priority)} · ${esc(due)}
      </div>
      ${targets.length > 0 ? `<div class="board-card-hint">можно: ${targets.map((t) => esc(statusLabel(t))).join(", ")}</div>` : ""}
    </article>`;
}
