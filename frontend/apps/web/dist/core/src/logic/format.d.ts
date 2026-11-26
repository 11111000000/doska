/** «26.11.2026» из ISO-строки; неразбираемое остаётся как было. */
export declare function formatDate(iso: string | null): string;
/** Возраст в целых сутках от отметки до сейчас. */
export declare function ageDays(iso: string, now?: Date): number;
/** «2 дн» / «5 ч» / «сейчас» — возраст короткой строкой. */
export declare function ageShort(iso: string, now?: Date): string;
//# sourceMappingURL=format.d.ts.map