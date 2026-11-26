// Форматтеры: человек читает «2 дня» и «26.11», а не ISO-строки.

/** «26.11.2026» из ISO-строки; неразбираемое остаётся как было. */
export function formatDate(iso: string | null): string {
  if (iso === null) return "—";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  const day = String(date.getDate()).padStart(2, "0");
  const month = String(date.getMonth() + 1).padStart(2, "0");
  return `${day}.${month}.${date.getFullYear()}`;
}

/** Возраст в целых сутках от отметки до сейчас. */
export function ageDays(iso: string, now: Date = new Date()): number {
  const created = new Date(iso).getTime();
  if (Number.isNaN(created)) return 0;
  return Math.floor((now.getTime() - created) / (24 * 60 * 60 * 1000));
}

/** «2 дн» / «5 ч» / «сейчас» — возраст короткой строкой. */
export function ageShort(iso: string, now: Date = new Date()): string {
  const ms = now.getTime() - new Date(iso).getTime();
  if (Number.isNaN(ms)) return "—";
  const minutes = Math.floor(ms / 60000);
  if (minutes < 1) return "сейчас";
  if (minutes < 60) return `${minutes} мин`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} ч`;
  return `${Math.floor(hours / 24)} дн`;
}
