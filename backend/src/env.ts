export interface WorkerEnvironment {
  DB: D1Database;
  PUBLIC_ASSETS: R2Bucket;
  STAGING_ASSETS: R2Bucket;
  ADMIN_ORIGINS?: string;
  PUBLIC_ASSETS_BASE_URL: string;
}
