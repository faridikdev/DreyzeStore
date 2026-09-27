export interface WorkerEnvironment {
  DB: D1Database;
  PASSWORD_KDF: DurableObjectNamespace;
  PUBLIC_ASSETS: R2Bucket;
  STAGING_ASSETS: R2Bucket;
  ADMIN_ORIGINS?: string;
  PUBLIC_ASSETS_BASE_URL: string;
  PUBLIC_API_BASE_URL?: string;
  PUBLIC_BUCKET_NAME?: string;
  STAGING_BUCKET_NAME?: string;
  R2_ACCOUNT_ID?: string;
  R2_ACCESS_KEY_ID?: string;
  R2_SECRET_ACCESS_KEY?: string;
  GITHUB_OWNER?: string;
  GITHUB_REPOSITORY?: string;
  GITHUB_APP_ID?: string;
  GITHUB_INSTALLATION_ID?: string;
  GITHUB_APP_PRIVATE_KEY?: string;
  GITHUB_VALIDATOR_WORKFLOW?: string;
  GITHUB_VALIDATOR_REF?: string;
  VALIDATOR_API_BASE_URL?: string;
  VALIDATOR_OIDC_AUDIENCE?: string;
  VALIDATOR_OIDC_JWKS_URL?: string;
  ADMIN_CSRF_SECRET?: string;
  ADMIN_RATE_LIMIT_HMAC_KEY?: string;
  SECURE_COOKIES?: string;
  LOCAL_UPLOADS_ENABLED?: string;
  LOCAL_VALIDATOR_ENABLED?: string;
  /** Test-only seams. They are never bound by wrangler.jsonc or deployment config. */
  TEST_FETCH?: typeof fetch;
  TEST_VALIDATOR_KEY?: CryptoKey;
}
