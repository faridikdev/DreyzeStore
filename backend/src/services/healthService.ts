import type { WorkerEnvironment } from "../env.js";
import { isDatabaseReady } from "../db/healthRepository.js";

export interface HealthState {
  status: "ok";
  database: "ready";
}

export async function readHealth(environment: WorkerEnvironment): Promise<HealthState | null> {
  return (await isDatabaseReady(environment)) ? { status: "ok", database: "ready" } : null;
}
