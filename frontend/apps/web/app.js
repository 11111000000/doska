// Входная точка веб-интерфейса: токен → клиент ядра → экраны.
// Без сборщика: ядро подключается собранными ES-модулями (D4-R).

import { DoskaClient } from "./core/src/index.js";
import { renderMyTasks } from "./tasks-view.js";
import { renderCard } from "./card-view.js";
import { renderBoard } from "./board-view.js";
import { renderOverview } from "./overview-view.js";

const TOKEN_KEY = "doska_token";
const view = document.getElementById("view");

export const state = {
  get token() { return localStorage.getItem(TOKEN_KEY) ?? ""; },
  set token(value) {
    if (value === "") localStorage.removeItem(TOKEN_KEY);
    else localStorage.setItem(TOKEN_KEY, value);
  },
  client: null,
  screen: "mine",
  tasks: [],
  projects: [],
  project: "",
  assignee: "",
  kind: "",
  overview: null,
};

export function client() {
  if (!state.client) {
    state.client = new DoskaClient({ baseUrl: window.location.origin, token: state.token });
  }
  return state.client;
}

export function render(html) { view.innerHTML = html; }
export function showError(error) {
  const box = document.createElement("div");
  box.className = "error";
  box.textContent = error.message ?? String(error);
  view.appendChild(box);
}

function tokenScreen(message = "") {
  state.client = null;
  render(`
    <h2>Токен доступа</h2>
    <p>Токен выдаёт администратор: POST /api/v1/credentials. Вставьте его сюда.</p>
    <input id="token" placeholder="dsk_…" style="width:32rem" />
    <button class="primary" id="save">Сохранить</button>
    <div class="error">${message}</div>
  `);
  document.getElementById("save").onclick = async () => {
    state.token = document.getElementById("token").value.trim();
    state.client = null;
    await enter();
  };
}

async function myTasksScreen() {
  const result = await client().myTasks();
  if (!result.ok) return showError(result.error);
  renderMyTasks(view, {
    page: result.value,
    actor: state.actor,
    onOpen: (ref) => cardScreen(ref),
    onRefresh: myTasksScreen,
  });
}

async function cardScreen(ref) {
  const result = await client().getTask(ref);
  if (!result.ok) return showError(result.error);
  renderCard(view, {
    details: result.value,
    client: client(),
    onBack: () => (state.screen === "board" ? boardScreen() : myTasksScreen()),
    onChanged: () => cardScreen(ref),
    onError: showError,
  });
}

async function loadBoard() {
  const filters = {
    limit: 100,
    ...(state.project ? { project: state.project } : {}),
    ...(state.assignee ? { assignee: state.assignee } : {}),
    ...(state.kind ? { kind: state.kind } : {}),
  };
  const result = await client().listTasks(filters);
  if (!result.ok) {
    showError(result.error);
    return;
  }
  state.tasks = result.value.items;
}

async function boardScreen() {
  const [projects, tasks] = await Promise.all([loadProjects(), loadBoard()]);
  if (!tasks) return;
  renderBoard(view, {
    client: client(),
    state,
    onRefresh: boardScreen,
  });
}

async function loadProjects() {
  if (state.projects.length > 0) return;
  const result = await client().projects();
  if (result.ok) state.projects = result.value;
}

async function overviewScreen() {
  const result = await client().overview();
  if (!result.ok) return showError(result.error);
  state.overview = result.value;
  renderOverview(view, {
    overview: result.value,
    onOpenTask: (ref) => cardScreen(ref),
  });
}

const screens = {
  mine: myTasksScreen,
  board: boardScreen,
  overview: overviewScreen,
};

function show(screen) {
  state.screen = screen;
  for (const link of document.querySelectorAll("#nav a")) {
    link.classList.toggle("active", link.dataset.screen === screen);
  }
  return screens[screen]().catch((e) => showError({ message: String(e) }));
}

async function enter() {
  const probe = await client().projects();
  if (!probe.ok) {
    tokenScreen(probe.error.message === "" ? "" : probe.error.message);
    return;
  }
  state.projects = probe.value;
  await show(state.screen);
}

document.getElementById("nav").addEventListener("click", (event) => {
  const link = event.target.closest("a[data-screen]");
  if (!link) return;
  event.preventDefault();
  show(link.dataset.screen).catch((e) => showError({ message: String(e) }));
});

document.getElementById("logout").onclick = () => { state.token = ""; tokenScreen(); };

if (state.token === "") tokenScreen();
else enter().catch((e) => showError({ message: String(e) }));
