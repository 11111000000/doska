import { type Task } from "../types.js";
export declare const URGENCY_BUCKETS: readonly ["overdue", "today", "week", "later", "no_deadline", "waits_for_me"];
export type UrgencyBucket = (typeof URGENCY_BUCKETS)[number];
export interface Bucket {
    bucket: UrgencyBucket;
    tasks: Task[];
}
/** Корзина одной задачи: отметка времени — «сейчас» клиента. */
export declare function bucketOf(task: Task, now: Date): UrgencyBucket;
/** Разложить открытые задачи по корзинам; порядок внутри — как в SQL. */
export declare function groupByUrgency(tasks: Task[], now?: Date): Bucket[];
//# sourceMappingURL=urgency.d.ts.map