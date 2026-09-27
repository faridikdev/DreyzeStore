import { Hono } from "hono";
import { ApiError } from "../errors.js";
import type { WorkerEnvironment } from "../env.js";
import { assertCsrf, requireAdmin, requireRole, type AdminEnvironment } from "../security/adminSecurity.js";
import { readBoundedJson } from "../security/requestBody.js";
import {
  createAppDraft,
  deleteDraftApp,
  editAppDraft,
  getAdminApp,
  getAdminApps,
  getAdminDashboard,
  getAdminFormOptions,
  unpublishApp,
} from "../services/adminCatalogService.js";
import {
  acceptLocalAssetBody,
  completeAssetUpload,
  createAssetUpload,
  deleteScreenshot,
  getFeaturedApps,
  listScreenshots,
  reorderScreenshots,
  setFeaturedApps,
} from "../services/adminAssetService.js";
import {
  acceptLocalPackageBody,
  completePackageUpload,
  createPackageUpload,
  getAdminUpload,
  publishRelease,
  rejectPackageUpload,
  saveReleaseReview,
  acceptValidatorReport,
  requestValidatorLease,
} from "../services/adminPublishingService.js";

type AppEnvironment = { Bindings: WorkerEnvironment; Variables: AdminEnvironment["Variables"] };

export const adminRoutes = new Hono<AppEnvironment>();
adminRoutes.use("/admin/*", requireAdmin());

adminRoutes.get("/admin/dashboard", async (context) => {
  context.header("Cache-Control", "no-store");
  return context.json({ data: await getAdminDashboard(context.env) });
});

adminRoutes.get("/admin/categories", async (context) => {
  context.header("Cache-Control", "no-store");
  return context.json({ data: (await getAdminFormOptions(context.env)).categories });
});

adminRoutes.get("/admin/repositories", async (context) => {
  context.header("Cache-Control", "no-store");
  return context.json({ data: (await getAdminFormOptions(context.env)).repositories });
});

adminRoutes.get("/admin/apps", async (context) => {
  const query = context.req.query("q") ?? "";
  context.header("Cache-Control", "no-store");
  return context.json({ data: await getAdminApps(context.env, query) });
});

adminRoutes.post("/admin/apps", async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 24_000, ["name", "bundleIdentifier", "developer", "categoryId", "description", "shortDescription", "repositoryId"]);
  const created = await createAppDraft(context.env, context.get("admin"), context.get("requestId"), body as never);
  return context.json({ data: created }, 201);
});

adminRoutes.get("/admin/apps/:id", async (context) => {
  context.header("Cache-Control", "no-store");
  const app = await getAdminApp(context.env, context.req.param("id"));
  const [screenshots, uploads] = await Promise.all([
    listScreenshots(context.env, app.id),
    context.env.DB.prepare("SELECT id FROM upload_jobs WHERE app_id = ? ORDER BY created_at DESC LIMIT 50")
      .bind(app.id).all<{ id: string }>(),
  ]);
  const releases = await context.env.DB.prepare(
    "SELECT id, version, build, minimum_ios AS minimumOSVersion, size, sha256, release_notes AS releaseNotes, channel, published_at AS publishedAt " +
    "FROM versions WHERE app_id = ? ORDER BY created_at DESC LIMIT 50",
  ).bind(app.id).all();
  return context.json({ data: { ...app, screenshots, uploads: (uploads.results ?? []).map((row) => row.id), releases: releases.results ?? [] } });
});

adminRoutes.patch("/admin/apps/:id", async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 24_000, ["name", "bundleIdentifier", "developer", "categoryId", "description", "shortDescription", "repositoryId"]);
  const saved = await editAppDraft(context.env, context.get("admin"), context.get("requestId"), context.req.param("id"), body as never);
  return context.json({ data: saved });
});

adminRoutes.delete("/admin/apps/:id", requireRole("admin"), async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 1024, ["confirm"]);
  if (body["confirm"] !== true) throw new ApiError(400, "confirmation_required", "Confirm deleting this draft.");
  await deleteDraftApp(context.env, context.get("admin"), context.get("requestId"), context.req.param("id"));
  return context.json({ data: { deleted: true } });
});

adminRoutes.post("/admin/apps/:id/unpublish", requireRole("admin"), async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 1024, ["confirm"]);
  if (body["confirm"] !== true) throw new ApiError(400, "confirmation_required", "Confirm unpublishing this application.");
  return context.json({ data: await unpublishApp(context.env, context.get("admin"), context.get("requestId"), context.req.param("id")) });
});

adminRoutes.get("/admin/apps/:id/screenshots", async (context) => {
  context.header("Cache-Control", "no-store");
  return context.json({ data: await listScreenshots(context.env, context.req.param("id")) });
});

adminRoutes.post("/admin/apps/:id/assets", async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 2048, ["kind", "size", "contentType", "altText"]);
  const input = {
    kind: body["kind"],
    size: body["size"],
    contentType: body["contentType"],
    ...(typeof body["altText"] === "string" ? { altText: body["altText"] } : {}),
  };
  return context.json({ data: await createAssetUpload(
    context.env, context.get("admin"), context.get("requestId"), context.req.param("id"), input as never,
  ) }, 201);
});

adminRoutes.put("/admin/assets/:id/local", async (context) => {
  await assertCsrf(context);
  await acceptLocalAssetBody(context.env, context.req.param("id"), context.req.raw);
  return context.json({ data: { uploaded: true } });
});

adminRoutes.post("/admin/assets/:id/complete", async (context) => {
  await assertCsrf(context);
  return context.json({ data: await completeAssetUpload(context.env, context.get("admin"), context.get("requestId"), context.req.param("id")) });
});

adminRoutes.delete("/admin/apps/:id/screenshots/:screenshotId", async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 1024, ["confirm"]);
  if (body["confirm"] !== true) throw new ApiError(400, "confirmation_required", "Confirm removing this screenshot.");
  return context.json({ data: await deleteScreenshot(
    context.env, context.get("admin"), context.get("requestId"), context.req.param("id"), context.req.param("screenshotId"),
  ) });
});

adminRoutes.put("/admin/apps/:id/screenshots/order", async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 8192, ["screenshotIds"]);
  if (!Array.isArray(body["screenshotIds"]) || body["screenshotIds"].some((id) => typeof id !== "string")) {
    throw new ApiError(400, "invalid_screenshot_order", "Provide a list of screenshot identifiers.");
  }
  return context.json({ data: await reorderScreenshots(
    context.env, context.get("admin"), context.get("requestId"), context.req.param("id"), body["screenshotIds"] as string[],
  ) });
});

adminRoutes.post("/admin/apps/:id/uploads", async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 1024, ["size"]);
  return context.json({ data: await createPackageUpload(
    context.env, context.get("admin"), context.get("requestId"), context.req.param("id"), { size: body["size"] as number },
  ) }, 201);
});

adminRoutes.put("/admin/uploads/:id/local", async (context) => {
  await assertCsrf(context);
  await acceptLocalPackageBody(context.env, context.req.param("id"), context.req.raw);
  return context.json({ data: { uploaded: true } });
});

adminRoutes.post("/admin/uploads/:id/complete", async (context) => {
  await assertCsrf(context);
  return context.json({ data: await completePackageUpload(
    context.env, context.get("admin"), context.get("requestId"), context.req.param("id"),
  ) });
});

adminRoutes.get("/admin/uploads/:id", async (context) => {
  context.header("Cache-Control", "no-store");
  return context.json({ data: await getAdminUpload(context.env, context.req.param("id")) });
});

adminRoutes.patch("/admin/uploads/:id", async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 12_000, ["releaseNotes", "channel"]);
  if (typeof body["releaseNotes"] !== "string" || (body["channel"] !== "stable" && body["channel"] !== "beta")) {
    throw new ApiError(400, "invalid_release", "Release notes and channel are required.");
  }
  return context.json({ data: await saveReleaseReview(
    context.env, context.get("admin"), context.get("requestId"), context.req.param("id"),
    { releaseNotes: body["releaseNotes"], channel: body["channel"] },
  ) });
});

adminRoutes.post("/admin/uploads/:id/publish", requireRole("admin"), async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 1024, ["confirmRights"]);
  return context.json({ data: await publishRelease(
    context.env, context.get("admin"), context.get("requestId"), context.req.param("id"), body["confirmRights"] === true,
  ) }, 201);
});

adminRoutes.post("/admin/uploads/:id/reject", requireRole("admin"), async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 1024, ["confirm"]);
  if (body["confirm"] !== true) throw new ApiError(400, "confirmation_required", "Confirm rejecting this upload.");
  return context.json({ data: await rejectPackageUpload(
    context.env, context.get("admin"), context.get("requestId"), context.req.param("id"),
  ) });
});

adminRoutes.get("/admin/featured", async (context) => {
  context.header("Cache-Control", "no-store");
  return context.json({ data: await getFeaturedApps(context.env) });
});

adminRoutes.put("/admin/featured/:section", async (context) => {
  await assertCsrf(context);
  const body = await readObject(context, 10_000, ["appIds"]);
  if (!Array.isArray(body["appIds"]) || body["appIds"].some((id) => typeof id !== "string")) {
    throw new ApiError(400, "invalid_featured_order", "Provide a list of application identifiers.");
  }
  return context.json({ data: await setFeaturedApps(
    context.env, context.get("admin"), context.get("requestId"), context.req.param("section"), body["appIds"] as string[],
  ) });
});

export const validatorRoutes = new Hono<{ Bindings: WorkerEnvironment; Variables: AdminEnvironment["Variables"] }>();
validatorRoutes.use("/validator/*", async (context, next) => {
  context.header("Cache-Control", "no-store");
  await next();
});
validatorRoutes.post("/validator/uploads/:id/lease", async (context) => {
  const token = bearer(context.req.header("Authorization"));
  const body = await readObject(context, 2048, ["dispatchTicket"]);
  if (typeof body["dispatchTicket"] !== "string" || body["dispatchTicket"].length > 128) {
    throw new ApiError(400, "invalid_validator_request", "The validator dispatch ticket is missing.");
  }
  return context.json({ data: await requestValidatorLease(context.env, context.req.param("id"), token, body["dispatchTicket"]) });
});

validatorRoutes.post("/validator/uploads/:id/result", async (context) => {
  const token = bearer(context.req.header("Authorization"));
  const body = await readObject(context, 8192, [
    "reportNonce", "result", "bundleIdentifier", "version", "build", "minimumOS", "displayName", "size", "sha256", "errorCode",
  ]);
  return context.json({ data: await acceptValidatorReport(
    context.env, context.req.param("id"), token, body,
  ) });
});

async function readObject(
  context: Parameters<typeof readBoundedJson>[0],
  max: number,
  allowed: string[],
): Promise<Record<string, unknown>> {
  const body = await readBoundedJson<unknown>(context, max);
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new ApiError(400, "invalid_request", "The request body must be a JSON object.");
  }
  const record = body as Record<string, unknown>;
  if (Object.keys(record).some((key) => !allowed.includes(key))) {
    throw new ApiError(400, "invalid_request", "The request contains unsupported fields.");
  }
  return record;
}

function bearer(value: string | undefined): string {
  const match = value?.match(/^Bearer ([A-Za-z0-9._-]{20,12000})$/u);
  if (!match) throw new ApiError(401, "validator_unauthenticated", "The validator identity was not accepted.");
  return match[1]!;
}
