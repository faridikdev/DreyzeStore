import type { WorkerEnvironment } from "../env.js";

export async function isDatabaseReady(environment: WorkerEnvironment): Promise<boolean> {
  const result = await environment.DB.prepare("SELECT 1 AS ready").first<{ ready: number }>();
  return result?.ready === 1;
}
