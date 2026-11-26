// Входная точка веб-интерфейса: токен → клиент ядра → экраны.
// Без сборщика: ядро подключается собранными ES-модулями (D4-R).

import { DoskaClient } from "./core/src/index.js";
import { renderMyTasks } from "./tasks-view.js";
import { renderCard } from "./card-view.js";

const TOKEN_KEY = "doska_token";
const view = document.getElementById("view");
document.getElementById("who").textContent = "";

export const state = {
  get token() { return localStorage.getItem(TOKEN_KEY) ?? ""; },
  set token(value) {
    if (value === "") localStorage.removeItem(TOKEN_KEY);
    else localStorage.setItem(TOKEN_KEY, value);
  },
  client: null,
  actor: null,
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
    onBack: myTasksScreen,
    onChanged: () => cardScreen(ref),
    onError: showError,
  });
}

async function enter() {
  // Проверка токена: whoami-подобный запрос — список проектов существует
  // и не требует прав; ошибка 401 вернёт на экран токена.
  const probe = await client().projects();
  if (!probe.ok) {
    tokenScreen(probe.error.message === "" ? "" : probe.error.message);
    return;
  }
  await myTasksScreen();
}

document.getElementById("nav-mine").onclick = () => myTasksScreen().catch(showError);
document.getElementById("logout").onclick = () => { state.token = ""; tokenScreen(); };

if (state.token === "") tokenScreen();
else enter().catch((e) => showError({ message: String(e) }));
