import { useCallback, useEffect, useState, type FormEvent } from "react";
import { apiRequest, apiURL, currentCsrfToken } from "../api/admin.js";
import type { AdminApp, AdminUpload, AppFormOptions } from "../types/admin.js";

interface AppDetail extends AdminApp {
  screenshots: Array<{ id: string; url: string; width: number; height: number; altText: string; ordinal: number }>;
  uploads: string[];
  releases: Array<{ id: string; version: string; build: string; minimumOSVersion: string; size: number; sha256: string; releaseNotes: string; channel: string; publishedAt: string | null }>;
}

interface UploadSession {
  id: string;
  uploadURL: string;
  requiredHeaders: Record<string, string>;
  expectedSize: number;
}

const emptyForm = { name: "", bundleIdentifier: "", developer: "", categoryId: "", description: "", shortDescription: "", repositoryId: "" };

export function AppsManager({ onChanged, isAdmin }: { onChanged: () => void; isAdmin: boolean }) {
  const [apps, setApps] = useState<AdminApp[]>([]);
  const [options, setOptions] = useState<AppFormOptions>({ categories: [], repositories: [] });
  const [selectedId, setSelectedId] = useState("");
  const [detail, setDetail] = useState<AppDetail | null>(null);
  const [upload, setUpload] = useState<AdminUpload | null>(null);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState("");
  const [creating, setCreating] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");

  const refreshApps = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const [nextApps, categories, repositories] = await Promise.all([
        apiRequest<AdminApp[]>(`/api/v1/admin/apps${query ? `?q=${encodeURIComponent(query)}` : ""}`),
        apiRequest<AppFormOptions["categories"]>("/api/v1/admin/categories"),
        apiRequest<AppFormOptions["repositories"]>("/api/v1/admin/repositories"),
      ]);
      setApps(nextApps);
      setOptions({ categories, repositories });
      if (selectedId && !nextApps.some((app) => app.id === selectedId)) setSelectedId("");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Applications could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, [query, selectedId]);

  useEffect(() => { void refreshApps(); }, [refreshApps]);

  const loadDetail = useCallback(async (id: string) => {
    setSelectedId(id);
    setCreating(false);
    setUpload(null);
    setNotice("");
    try {
      const value = await apiRequest<AppDetail>(`/api/v1/admin/apps/${encodeURIComponent(id)}`);
      setDetail(value);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Application details could not be loaded.");
    }
  }, []);

  useEffect(() => {
    if (!detail?.uploads.length) return;
    let active = true;
    void (async () => {
      const latestId = detail.uploads[0];
      if (!latestId) return;
      try {
        const latest = await apiRequest<AdminUpload>(`/api/v1/admin/uploads/${latestId}`);
        if (active) setUpload(latest);
      } catch { /* A deleted or expired upload is not fatal to the app editor. */ }
    })();
    return () => { active = false; };
  }, [detail]);

  useEffect(() => {
    if (!upload || !["queued", "validating"].includes(upload.state)) return;
    let active = true;
    const timer = window.setInterval(() => {
      void apiRequest<AdminUpload>(`/api/v1/admin/uploads/${upload.id}`)
        .then((next) => { if (active) setUpload(next); })
        .catch(() => undefined);
    }, 2500);
    return () => { active = false; window.clearInterval(timer); };
  }, [upload]);

  async function saveDraft(form: typeof emptyForm) {
    setBusy(true);
    setError("");
    try {
      const result = await apiRequest<AdminApp>(creating ? "/api/v1/admin/apps" : `/api/v1/admin/apps/${selectedId}`, {
        method: creating ? "POST" : "PATCH",
        body: JSON.stringify(form),
      });
      setNotice(creating ? "Draft created. Upload its icon and an authorized IPA to prepare a release." : "Application details saved.");
      setCreating(false);
      await refreshApps();
      await loadDetail(result.id);
      onChanged();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "The application could not be saved.");
    } finally { setBusy(false); }
  }

  async function uploadObject(file: File, session: UploadSession) {
    const target = new URL(session.uploadURL);
    const local = target.origin === new URL(apiURL("/" )).origin && target.pathname.endsWith("/local");
    const headers = new Headers(session.requiredHeaders);
    if (local) headers.set("X-CSRF-Token", currentCsrfToken());
    const response = await fetch(session.uploadURL, {
      method: "PUT",
      headers,
      body: file,
      credentials: local ? "include" : "omit",
      cache: "no-store",
    });
    if (!response.ok) throw new Error(`Upload failed with HTTP ${response.status}.`);
  }

  async function uploadAppAsset(file: File, kind: "icon" | "screenshot") {
    if (!detail) return;
    setBusy(true); setError(""); setNotice("");
    try {
      const session = await apiRequest<UploadSession>(`/api/v1/admin/apps/${detail.id}/assets`, {
        method: "POST",
        body: JSON.stringify({ kind, size: file.size, contentType: file.type, ...(kind === "screenshot" ? { altText: file.name } : {}) }),
      });
      await uploadObject(file, session);
      await apiRequest(`/api/v1/admin/assets/${session.id}/complete`, { method: "POST" });
      setNotice(kind === "icon" ? "Icon uploaded and validated." : "Screenshot uploaded and validated.");
      await loadDetail(detail.id);
      onChanged();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "The image could not be uploaded.");
    } finally { setBusy(false); }
  }

  async function uploadPackage(file: File) {
    if (!detail) return;
    setBusy(true); setError(""); setNotice(""); setUpload(null);
    try {
      const session = await apiRequest<UploadSession>(`/api/v1/admin/apps/${detail.id}/uploads`, {
        method: "POST", body: JSON.stringify({ size: file.size }),
      });
      setNotice("Uploading package to private staging…");
      await uploadObject(file, session);
      const result = await apiRequest<{ id: string; state: string }>(`/api/v1/admin/uploads/${session.id}/complete`, { method: "POST" });
      setNotice(result.state === "queued" ? "Package uploaded. Isolated validation has been queued." : "Package upload is complete.");
      setUpload(await apiRequest<AdminUpload>(`/api/v1/admin/uploads/${session.id}`));
      const latest = await apiRequest<AppDetail>(`/api/v1/admin/apps/${detail.id}`);
      setDetail(latest);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "The package could not be uploaded.");
    } finally { setBusy(false); }
  }

  async function saveReview(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!upload) return;
    const formData = new FormData(event.currentTarget);
    setBusy(true); setError("");
    try {
      const result = await apiRequest<AdminUpload>(`/api/v1/admin/uploads/${upload.id}`, {
        method: "PATCH",
        body: JSON.stringify({ releaseNotes: String(formData.get("releaseNotes") ?? ""), channel: String(formData.get("channel") ?? "stable") }),
      });
      setUpload(result);
      setNotice("Release review saved.");
    } catch (cause) { setError(cause instanceof Error ? cause.message : "The review could not be saved."); }
    finally { setBusy(false); }
  }

  async function publish(confirmRights: boolean) {
    if (!upload || !confirmRights || !isAdmin || !window.confirm("Publish this verified package to the public catalog?")) return;
    setBusy(true); setError("");
    try {
      await apiRequest(`/api/v1/admin/uploads/${upload.id}/publish`, { method: "POST", body: JSON.stringify({ confirmRights }) });
      setUpload(null);
      setNotice("Release published. It is now available through the public catalog API.");
      await refreshApps();
      if (detail) await loadDetail(detail.id);
      onChanged();
    } catch (cause) { setError(cause instanceof Error ? cause.message : "The release could not be published."); }
    finally { setBusy(false); }
  }

  async function rejectUpload() {
    if (!upload || !window.confirm("Reject this upload and remove its private staged object?")) return;
    setBusy(true); setError("");
    try {
      await apiRequest(`/api/v1/admin/uploads/${upload.id}/reject`, { method: "POST", body: JSON.stringify({ confirm: true }) });
      setUpload(null);
      setNotice("Upload rejected and its private staging object removed.");
      if (detail) await loadDetail(detail.id);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "The upload could not be rejected."); }
    finally { setBusy(false); }
  }

  async function doUnpublish() {
    if (!detail || !window.confirm("Unpublish this application from the public API?")) return;
    setBusy(true); setError("");
    try {
      await apiRequest(`/api/v1/admin/apps/${detail.id}/unpublish`, { method: "POST", body: JSON.stringify({ confirm: true }) });
      setNotice("Application unpublished.");
      await refreshApps();
      await loadDetail(detail.id);
      onChanged();
    } catch (cause) { setError(cause instanceof Error ? cause.message : "The app could not be unpublished."); }
    finally { setBusy(false); }
  }

  async function deleteDraft() {
    if (!detail || !window.confirm(`Delete the draft “${detail.name}”? This cannot be undone.`)) return;
    setBusy(true); setError("");
    try {
      await apiRequest(`/api/v1/admin/apps/${detail.id}`, { method: "DELETE", body: JSON.stringify({ confirm: true }) });
      setDetail(null); setSelectedId(""); setNotice("Draft deleted.");
      await refreshApps(); onChanged();
    } catch (cause) { setError(cause instanceof Error ? cause.message : "The draft could not be deleted."); }
    finally { setBusy(false); }
  }

  async function removeScreenshot(id: string) {
    if (!detail || !window.confirm("Remove this screenshot from the app?")) return;
    try {
      await apiRequest(`/api/v1/admin/apps/${detail.id}/screenshots/${id}`, { method: "DELETE", body: JSON.stringify({ confirm: true }) });
      await loadDetail(detail.id);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "The screenshot could not be removed."); }
  }

  async function moveScreenshot(index: number, delta: number) {
    if (!detail) return;
    const list = [...detail.screenshots];
    const target = index + delta;
    if (target < 0 || target >= list.length) return;
    [list[index], list[target]] = [list[target]!, list[index]!];
    try {
      await apiRequest(`/api/v1/admin/apps/${detail.id}/screenshots/order`, {
        method: "PUT", body: JSON.stringify({ screenshotIds: list.map((item) => item.id) }),
      });
      await loadDetail(detail.id);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Screenshot order could not be changed."); }
  }

  return (
    <div className="manager-layout">
      <aside className="list-panel">
        <div className="panel-title"><div><p className="eyebrow">CATALOG</p><h2>Apps</h2></div>
          <button className="primary small" onClick={() => { setSelectedId(""); setDetail(null); setCreating(true); setUpload(null); }}>New app</button></div>
        <label className="search-input"><span aria-hidden="true">⌕</span><input placeholder="Find an app" value={query} onChange={(event) => setQuery(event.target.value)} /></label>
        <div className="app-list" aria-busy={loading}>
          {loading ? <p className="muted list-message">Loading catalog…</p> : apps.length === 0 ? <p className="muted list-message">No matching apps.</p> : apps.map((app) => (
            <button key={app.id} className={`app-list-item ${selectedId === app.id ? "selected" : ""}`} onClick={() => void loadDetail(app.id)}>
              <span className="app-list-icon">{app.name.slice(0, 1).toUpperCase()}</span>
              <span className="app-list-copy"><strong>{app.name}</strong><small>{app.developer}</small></span>
              <span className={`state-pill ${app.published ? "good" : "neutral"}`}>{app.published ? "Published" : "Draft"}</span>
            </button>
          ))}
        </div>
      </aside>

      <section className="editor-panel">
        {(notice || error) && <p className={`notice ${error ? "error" : "success"}`} role={error ? "alert" : "status"}>{error || notice}</p>}
        {creating ? <AppForm key="create" title="Create application" options={options} initial={emptyForm} busy={busy} onCancel={() => setCreating(false)} onSave={(value) => void saveDraft(value)} /> : detail ? (
          <>
            <div className="editor-heading"><div><p className="eyebrow">{detail.published ? "PUBLISHED APP" : "DRAFT APP"}</p><h2>{detail.name}</h2><p className="muted">{detail.bundleIdentifier}</p></div>
              <div className="row-actions"><span className={`state-pill ${detail.published ? "good" : "neutral"}`}>{detail.published ? "Published" : "Draft"}</span>
                {isAdmin && detail.published && <button className="quiet danger-text" onClick={() => void doUnpublish()} disabled={busy}>Unpublish</button>}
                {isAdmin && !detail.published && detail.releaseCount === 0 && <button className="quiet danger-text" onClick={() => void deleteDraft()} disabled={busy}>Delete draft</button>}
              </div></div>
            <AppForm key={detail.id + detail.updatedAt} title="Application metadata" options={options} initial={{
              name: detail.name, bundleIdentifier: detail.bundleIdentifier, developer: detail.developer,
              categoryId: detail.categoryId, description: detail.description, shortDescription: detail.shortDescription,
              repositoryId: detail.repositoryId,
            }} busy={busy} submitLabel="Save changes" onSave={(value) => void saveDraft(value)} />

            <section className="work-card"><div className="section-title"><div><p className="eyebrow">MEDIA</p><h3>App artwork</h3></div><span className="state-pill neutral">PNG / JPEG</span></div>
              <div className="upload-row"><div><strong>Application icon</strong><p className="muted">Square, 64–1024 px. Required before publishing.</p></div>
                <label className="secondary file-button">Upload icon<input type="file" accept="image/png,image/jpeg" disabled={busy} onChange={(event) => { const file = event.target.files?.[0]; if (file) void uploadAppAsset(file, "icon"); event.currentTarget.value = ""; }} /></label></div>
              <div className="upload-row"><div><strong>Screenshots</strong><p className="muted">Up to 20 images, between 320 and 4096 px.</p></div>
                <label className="secondary file-button">Add screenshot<input type="file" accept="image/png,image/jpeg" disabled={busy || detail.screenshots.length >= 20} onChange={(event) => { const file = event.target.files?.[0]; if (file) void uploadAppAsset(file, "screenshot"); event.currentTarget.value = ""; }} /></label></div>
              {detail.screenshots.length > 0 && <div className="screenshot-grid">{detail.screenshots.map((shot, index) => <article className="screenshot-item" key={shot.id}>
                <img src={shot.url} alt={shot.altText} loading="lazy" /><div className="screenshot-controls"><span>{shot.width} × {shot.height}</span>
                  <button aria-label="Move screenshot earlier" disabled={index === 0} onClick={() => void moveScreenshot(index, -1)}>↑</button>
                  <button aria-label="Move screenshot later" disabled={index === detail.screenshots.length - 1} onClick={() => void moveScreenshot(index, 1)}>↓</button>
                  <button aria-label="Remove screenshot" className="danger-text" onClick={() => void removeScreenshot(shot.id)}>×</button></div></article>)}</div>}
            </section>

            <section className="work-card"><div className="section-title"><div><p className="eyebrow">PRIVATE STAGING</p><h3>New release</h3></div><span className="state-pill neutral">Up to 1 GiB</span></div>
              <div className="upload-row"><div><strong>Authorized IPA package</strong><p className="muted">Uploaded to private staging, inspected by the isolated validator, then reviewed here.</p></div>
                <label className="primary file-button">Choose IPA<input type="file" accept=".ipa,application/octet-stream" disabled={busy} onChange={(event) => { const file = event.target.files?.[0]; if (file) void uploadPackage(file); event.currentTarget.value = ""; }} /></label></div>
              {upload && <ReleaseReview key={upload.id} upload={upload} busy={busy} isAdmin={isAdmin} onSave={saveReview} onPublish={(confirmRights) => void publish(confirmRights)} onReject={() => void rejectUpload()} />}
            </section>

            <section className="work-card"><div className="section-title"><div><p className="eyebrow">RELEASE HISTORY</p><h3>Published releases</h3></div><span className="state-pill neutral">{detail.releases.length}</span></div>
              {detail.releases.length === 0 ? <p className="muted">No releases have been published.</p> : <div className="release-list">{detail.releases.map((release) => <div className="release-row" key={release.id}>
                <div><strong>{release.version} <span className="muted">({release.build})</span></strong><small>{release.channel} · iOS {release.minimumOSVersion} · {formatBytes(release.size)}</small></div>
                <code>{release.sha256.slice(0, 12)}…</code><span className="state-pill good">Published</span></div>)}</div>}
            </section>
          </>
        ) : <div className="empty-panel"><span className="empty-mark">D</span><h2>{loading ? "Loading apps" : "Choose an application"}</h2><p className="muted">Create a draft or select an app to edit its metadata and prepare a release.</p>
          {!loading && apps.length === 0 && <button className="primary" onClick={() => setCreating(true)}>Create first app</button>}</div>}
      </section>
    </div>
  );
}

function AppForm({ title, options, initial, busy, submitLabel = "Create draft", onSave, onCancel }: {
  title: string; options: AppFormOptions; initial: typeof emptyForm; busy: boolean; submitLabel?: string;
  onSave: (value: typeof emptyForm) => void; onCancel?: () => void;
}) {
  const [form, setForm] = useState(initial);
  const update = (key: keyof typeof emptyForm, value: string) => setForm((current) => ({ ...current, [key]: value }));
  return <form className="work-card form-stack" onSubmit={(event) => { event.preventDefault(); onSave(form); }}>
    <div className="section-title"><div><p className="eyebrow">DETAILS</p><h3>{title}</h3></div></div>
    <div className="form-grid">
      <label>App name<input value={form.name} onChange={(event) => update("name", event.target.value)} required maxLength={160} /></label>
      <label>Bundle identifier<input value={form.bundleIdentifier} onChange={(event) => update("bundleIdentifier", event.target.value)} required maxLength={255} disabled={submitLabel === "Save changes"} /><small>Locked after the first release.</small></label>
      <label>Developer<input value={form.developer} onChange={(event) => update("developer", event.target.value)} required maxLength={200} /></label>
      <label>Category<select value={form.categoryId} onChange={(event) => update("categoryId", event.target.value)} required><option value="">Choose a category</option>{options.categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select></label>
      <label>Official source<select value={form.repositoryId} onChange={(event) => update("repositoryId", event.target.value)} required><option value="">Choose a source</option>{options.repositories.map((repository) => <option key={repository.id} value={repository.id}>{repository.name}</option>)}</select></label>
      <label>Short description<input value={form.shortDescription} onChange={(event) => update("shortDescription", event.target.value)} required maxLength={160} /></label>
    </div>
    <label>Full description<textarea value={form.description} onChange={(event) => update("description", event.target.value)} required maxLength={20_000} rows={5} /></label>
    <div className="form-actions">{onCancel && <button className="quiet" type="button" onClick={onCancel}>Cancel</button>}<button className="primary" disabled={busy}>{busy ? "Saving…" : submitLabel}</button></div>
  </form>;
}

function ReleaseReview({ upload, busy, isAdmin, onSave, onPublish, onReject }: {
  upload: AdminUpload; busy: boolean; isAdmin: boolean; onSave: (event: FormEvent<HTMLFormElement>) => void;
  onPublish: (confirmRights: boolean) => void; onReject: () => void;
}) {
  const [rightsAccepted, setRightsAccepted] = useState(false);
  return <div className="review-block">
    <div className="upload-status"><strong>{upload.state.replaceAll("_", " ")}</strong><span className={`state-pill ${upload.state === "ready_for_review" ? "good" : upload.state === "validation_failed" ? "bad" : "neutral"}`}>{upload.state}</span></div>
    {upload.detectedPackage && <div className={`package-metadata ${upload.validationError ? "invalid" : ""}`}>
      <p className="eyebrow">DETECTED PACKAGE</p>
      <dl><dt>Bundle ID</dt><dd>{upload.detectedPackage.bundleIdentifier}</dd><dt>Version</dt><dd>{upload.detectedPackage.version} ({upload.detectedPackage.build})</dd>
        <dt>Minimum iOS</dt><dd>{upload.detectedPackage.minimumOS}</dd><dt>Size</dt><dd>{formatBytes(upload.detectedPackage.size ?? upload.expectedSize)}</dd>
        <dt>SHA-256</dt><dd><code>{upload.detectedPackage.sha256}</code></dd></dl>
      {upload.detectedPackage.bundleIdentifier !== upload.appBundleIdentifier && <p className="notice error">Bundle ID does not match the app record. Publishing is blocked.</p>}
    </div>}
    {upload.validationError && <p className="notice error">Validation failed: {upload.validationError}. This package cannot be published.</p>}
    {upload.state === "ready_for_review" && <form className="form-stack review-form" onSubmit={(event) => { event.preventDefault(); onSave(event); }}>
      <label>What’s New<textarea name="releaseNotes" defaultValue={upload.releaseNotes} maxLength={10_000} rows={3} /></label>
      <label>Release channel<select name="channel" defaultValue={upload.channel}><option value="stable">Stable</option><option value="beta">Beta</option></select></label>
      {isAdmin ? <label className="check-label"><input name="rights" type="checkbox" checked={rightsAccepted} onChange={(event) => setRightsAccepted(event.target.checked)} required />I confirm that I have the right to distribute this application/package.</label> : <p className="fine-print">An administrator must confirm distribution rights before publishing.</p>}
      <div className="form-actions">{isAdmin && <button className="quiet danger-text" type="button" onClick={onReject} disabled={busy}>Reject upload</button>}
        <button className="secondary" type="submit" disabled={busy}>Save review</button>
        {isAdmin && <button className="primary" type="button" onClick={() => onPublish(rightsAccepted)} disabled={busy || !rightsAccepted || upload.detectedPackage?.bundleIdentifier !== upload.appBundleIdentifier}>Publish release</button>}</div>
      <p className="fine-print">The rights confirmation is recorded with your account and release. It does not replace the package’s client-side SHA-256 and IPA checks.</p>
    </form>}
    {!["ready_for_review", "validation_failed", "rejected", "published"].includes(upload.state) && <p className="muted">Validation runs without publishing access. This panel refreshes while the job is active.</p>}
  </div>;
}

export function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  const level = Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1);
  return `${(value / 1024 ** level).toFixed(level === 0 ? 0 : 1)} ${units[level]}`;
}
