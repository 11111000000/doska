import test from "node:test";
import assert from "node:assert/strict";
import { ageDays, ageShort, formatDate } from "../src/logic/format.js";

const NOW = new Date("2026-11-26T12:00:00Z");

test("дата читается человеком", () => {
  assert.equal(formatDate("2026-11-26T12:00:00Z"), "26.11.2026");
  assert.equal(formatDate(null), "—");
  assert.equal(formatDate("не дата"), "не дата");
});

test("возраст считается в сутках", () => {
  assert.equal(ageDays("2026-11-24T12:00:00Z", NOW), 2);
  assert.equal(ageDays("мусор", NOW), 0);
});

test("возраст короткой строкой", () => {
  assert.equal(ageShort("2026-11-26T11:59:59Z", NOW), "сейчас");
  assert.equal(ageShort("2026-11-26T11:59:00Z", NOW), "1 мин");
  assert.equal(ageShort("2026-11-26T10:00:00Z", NOW), "2 ч");
  assert.equal(ageShort("2026-11-24T12:00:00Z", NOW), "2 дн");
});
