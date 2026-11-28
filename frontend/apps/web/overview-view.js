// Обзор трекера: нагрузка по людям и проектам, застрявшие, ждут ответа.
//
// Визуализации — на D3 (единственная runtime-зависимость веба, ADR §6.4):
// данные приходят из GET /api/v1/overview, D3 только рисует по ним и
// состояние не мутирует.

import { STATUS_LABELS } from "./core/src/index.js";

const esc = (s) =>
  String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

const COLORS = {
  open: "#4f8cff",
  in_progress: "#8b5cf6",
  needs_input: "#f59e0b",
  stuck: "#ff6b6b",
  muted: "#3a4356",
  text: "#8a93a6",
};

export function renderOverview(root, { overview, onOpenTask }) {
  const d3 = window.d3;
  if (!d3) {
    root.innerHTML = "<p class='error'>D3 не загрузился: сборка веба без vendor/d3.min.js</p>";
    return;
  }

  const totals = overview.totals;
  root.innerHTML = `
    <h2>Обзор</h2>
    <div class="metrics">
      ${metric("Открыто", totals.open_tasks)}
      ${metric("В работе", totals.in_progress)}
      ${metric("Заблокировано", totals.blocked)}
      ${metric("Ждут ответа", totals.needs_input)}
      ${metric("Без исполнителя", totals.unassigned)}
      ${metric("Без проекта", totals.without_project)}
    </div>
    <div class="charts">
      <figure><figcaption>Нагрузка по людям (открытые задачи)</figcaption>
        <svg id="wip-chart" role="img" aria-label="Нагрузка по людям"></svg></figure>
      <figure><figcaption>Нагрузка по проектам</figcaption>
        <svg id="project-chart" role="img" aria-label="Нагрузка по проектам"></svg></figure>
    </div>
    <div class="lists">
      <section><h3>Застряли (${overview.stuck.length})</h3>${agedList(overview.stuck, onOpenTask)}</section>
      <section><h3>Ждут ответа (${overview.needs_input.length})</h3>${agedList(overview.needs_input, onOpenTask)}</section>
    </div>`;

  drawWip(d3, root.querySelector("#wip-chart"), overview.wip_by_actor);
  drawProjects(d3, root.querySelector("#project-chart"), overview.by_project);
}

function metric(label, value) {
  return `<div class="metric"><div class="metric-value">${value}</div><div class="metric-label">${esc(label)}</div></div>`;
}

function agedList(items, onOpenTask) {
  if (items.length === 0) return "<p>пусто</p>";
  return `<ul>${items
    .map(
      (item) => `<li><a href="#" data-ref="${esc(item.task.ref)}">${esc(item.task.ref)}</a> — ${esc(
        item.task.title,
      )} <span class="muted">${esc(STATUS_LABELS[item.task.status] ?? item.task.status)} · ${item.age_days} дн</span></li>`,
    )
    .join("")}</ul>`;
}

function drawWip(d3, svg, actors) {
  svg.selectAll("*").remove();
  const width = 620;
  const rowHeight = 30;
  const height = Math.max(120, actors.length * rowHeight + 36);
  svg.attr("viewBox", `0 0 ${width} ${height}`).attr("width", "100%");

  const max = d3.max(actors, (a) => a.open_tasks) ?? 0;
  const x = d3.scaleLinear().domain([0, Math.max(1, max)]).range([140, width - 12]);
  const y = d3.scaleBand().domain(actors.map((a) => a.display_name || a.handle)).range([8, height - 28]).padding(0.16);

  const chart = svg.append("g");

  chart
    .selectAll("g.actor")
    .data(actors)
    .join("g")
    .attr("class", "actor")
    .attr("transform", (a) => `translate(0, ${y(a.display_name || a.handle)})`)
    .each(function (a) {
      const row = d3.select(this);
      const rest = Math.max(0, a.open_tasks - a.in_progress - a.needs_input);
      const segments = [
        { value: rest, color: COLORS.muted, title: "открытые" },
        { value: a.in_progress, color: COLORS.in_progress, title: "в работе" },
        { value: a.needs_input, color: COLORS.needs_input, title: "ждут ответа" },
      ];
      let offset = 0;
      segments.forEach((segment) => {
        if (segment.value <= 0) return;
        row
          .append("rect")
          .attr("x", x(offset))
          .attr("y", 0)
          .attr("height", y.bandwidth())
          .attr("width", Math.max(0, x(segment.value) - x(0)))
          .attr("fill", segment.color)
          .append("title")
          .text(`${segment.title}: ${segment.value}`);
        offset += segment.value;
      });
      row
        .append("text")
        .attr("x", -8)
        .attr("y", y.bandwidth() / 2 + 4)
        .attr("text-anchor", "end")
        .attr("fill", COLORS.text)
        .attr("font-size", 12)
        .text(a.display_name || a.handle);
    });

  svg
    .append("g")
    .attr("transform", `translate(0, ${height - 18})`)
    .call(d3.axisBottom(x).ticks(5))
    .call((g) => g.selectAll("text").attr("fill", COLORS.text))
    .call((g) => g.selectAll("line,path").attr("stroke", COLORS.border ?? "#263041"));
}

function drawProjects(d3, svg, projects) {
  svg.selectAll("*").remove();
  const width = 620;
  const height = 240;
  svg.attr("viewBox", `0 0 ${width} ${height}`).attr("width", "100%");

  const x = d3.scaleBand().domain(projects.map((p) => p.key)).range([10, width - 10]).padding(0.25);
  const y = d3.scaleLinear().domain([0, d3.max(projects, (p) => p.open_tasks) ?? 1]).nice().range([height - 40, 10]);

  const chart = svg.append("g");
  chart
    .selectAll("rect.open")
    .data(projects)
    .join("rect")
    .attr("class", "open")
    .attr("x", (p) => x(p.key))
    .attr("y", (p) => y(p.open_tasks))
    .attr("width", x.bandwidth())
    .attr("height", (p) => height - 40 - y(p.open_tasks))
    .attr("fill", COLORS.open)
    .append("title")
    .text((p) => `${p.name}: ${p.open_tasks}`);

  chart
    .selectAll("rect.stuck")
    .data(projects.filter((p) => p.stuck > 0))
    .join("rect")
    .attr("class", "stuck")
    .attr("x", (p) => x(p.key) + x.bandwidth() * 0.62)
    .attr("y", (p) => y(p.stuck))
    .attr("width", x.bandwidth() * 0.38)
    .attr("height", (p) => height - 40 - y(p.stuck))
    .attr("fill", COLORS.stuck)
    .append("title")
    .text((p) => `${p.name}: застряло ${p.stuck}`);

  chart
    .selectAll("text.label")
    .data(projects)
    .join("text")
    .attr("class", "label")
    .attr("x", (p) => (x(p.key) ?? 0) + x.bandwidth() / 2)
    .attr("y", height - 22)
    .attr("text-anchor", "middle")
    .attr("fill", COLORS.text)
    .attr("font-size", 11)
    .text((p) => p.key);

  svg
    .append("g")
    .attr("transform", "translate(0, 0)")
    .call(d3.axisLeft(y).ticks(4))
    .call((g) => g.selectAll("text").attr("fill", COLORS.text))
    .call((g) => g.selectAll("line,path").attr("stroke", "#263041"));
}
