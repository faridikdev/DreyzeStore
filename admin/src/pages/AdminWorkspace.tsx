import { useCallback, useEffect, useState } from "react";
import { apiRequest, type AdminSession } from "../api/admin.js";
import { AppsManager, formatBytes } from "../features/AppsManager.js";
import type { AdminApp, AdminDashboardData } from "../types/admin.js";

type Section = "overview" | "apps" | "featured" | "storage";
type FeaturedEntry = { sectionKey: string; ordinal: number; appId: string; name: string; bundleIdentifier: string };

export function AdminWorkspace({ session, onSignOut }: { session: AdminSession; onSignOut: () => void }) {
  const [section, setSection] = useState<Section>("overview");
  const [dashboard, setDashboard] = useState<AdminDashboardData | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [dashboardError, setDashboardError] = useState("");
  const refreshDashboard = useCallback(() => setRefreshKey((value) => value + 1), []);

  useEffect(() => {
    let active = true;
    void apiRequest<AdminDashboardData>("/api/v1/admin/dashboard")
      .then((value) => { if (active) { setDashboard(value); setDashboardError(""); } })
      .catch((cause) => { if (active) setDashboardError(cause instanceof Error ? cause.message : "Dashboard data is unavailable."); });
    return () => { active = false; };
  }, [refreshKey]);

  const navigation: Array<{ id: Section; label: string; symbol: string }> = [
    { id: "overview", label: "Overview", symbol: "◫" },
    { id: "apps", label: "Apps", symbol: "▣" },
    { id: "featured", label: "Featured", symbol: "✳" },
    { id: "storage", label: "Storage", symbol: "◉" },
  ];

  return <div className="admin-shell">
    <aside className="sidebar">
      <a className="brand-lockup" href="#overview" onClick={() => setSection("overview")}><span className="wordmark-mark">D</span><span>DreyzeStore <i>Admin</i></span></a>
      <p className="side-label">WORKSPACE</p>
      <nav aria-label="Admin navigation">{navigation.map((item) => <button key={item.id} className={`nav-item ${section === item.id ? "active" : ""}`} onClick={() => setSection(item.id)}>
        <span aria-hidden="true">{item.symbol}</span>{item.label}{item.id === "apps" && dashboard && <small>{dashboard.apps}</small>}</button>)}</nav>
      <div className="sidebar-spacer" />
      <div className="account-card"><span className="avatar">{session.email.slice(0, 1).toUpperCase()}</span><div><strong>{session.email}</strong><small>{session.role}</small></div><button aria-label="Sign out" title="Sign out" onClick={onSignOut}>↪</button></div>
    </aside>

    <main className="main-column">
      <header className="workspace-topbar"><div className="breadcrumbs"><span>Store</span><span>/</span><strong>{navigation.find((item) => item.id === section)?.label}</strong></div>
        <div className="topbar-meta"><span className="secure-label"><span aria-hidden="true">●</span> Secure session</span><button className="quiet" onClick={onSignOut}>Sign out</button></div></header>
      <div className="content-area">
        {section === "overview" && <Overview dashboard={dashboard} error={dashboardError} onNavigate={setSection} />}
        {section === "apps" && <div className="page-heading compact"><p className="eyebrow">STORE CONTENT</p><h1>Apps</h1><p className="muted">Manage drafts, validated packages, and public releases.</p><AppsManager isAdmin={session.role === "admin"} onChanged={refreshDashboard} /></div>}
        {section === "featured" && <FeaturedManager onChanged={refreshDashboard} />}
        {section === "storage" && <StoragePage dashboard={dashboard} />}
      </div>
      <footer className="workspace-footer"><span>DreyzeStore Admin</span><span>Changes are recorded in the audit log.</span></footer>
    </main>
  </div>;
}

function Overview({ dashboard, error, onNavigate }: { dashboard: AdminDashboardData | null; error: string; onNavigate: (section: Section) => void }) {
  return <>
    <div className="page-heading"><p className="eyebrow">STORE OPERATIONS</p><h1>Good day.</h1><p className="muted">A quiet overview of the DreyzeStore catalog and its release queue.</p></div>
    {error && <p className="notice error" role="alert">{error}</p>}
    {!dashboard ? <div className="work-card loading-card" role="status">Loading store activity…</div> : <>
      <div className="metric-grid">
        <Metric label="Apps" value={dashboard.apps.toString()} caption={`${dashboard.drafts} drafts`} icon="▣" />
        <Metric label="Published" value={dashboard.published.toString()} caption="Visible in the public catalog" icon="◉" />
        <Metric label="Releases" value={dashboard.releases.toString()} caption={`${dashboard.pendingUploads} uploads in progress`} icon="↥" />
        <Metric label="Published package bytes" value={formatBytes(dashboard.storageBytes)} caption="R2 distribution objects" icon="▤" />
      </div>
      <div className="overview-grid">
        <section className="work-card quick-card"><div className="section-title"><div><p className="eyebrow">NEXT STEP</p><h2>Prepare a release</h2></div><span className="mini-icon">↥</span></div>
          <p className="muted">Create a draft, upload an authorized IPA to private staging, then review the metadata returned by the isolated validator.</p>
          <button className="primary" onClick={() => onNavigate("apps")}>Open apps</button></section>
        <section className="work-card"><div className="section-title"><div><p className="eyebrow">TODAY</p><h2>Featured content</h2></div><button className="text-button" onClick={() => onNavigate("featured")}>Manage</button></div>
          <p className="muted">Order published apps for Today. Draft applications are filtered by the API.</p></section>
      </div>
      <section className="work-card activity-card"><div className="section-title"><div><p className="eyebrow">AUDIT</p><h2>Recent activity</h2></div><span className="state-pill neutral">Latest 20</span></div>
        {dashboard.recentActivity.length === 0 ? <p className="muted">No admin activity has been recorded yet.</p> : <div className="activity-list">{dashboard.recentActivity.map((event) => <div className="activity-row" key={event.id}>
          <span className="activity-marker" /><div><strong>{humanize(event.action)}</strong><small>{event.actor} · {event.resourceType}{event.resourceId ? ` · ${event.resourceId}` : ""}</small></div><time dateTime={event.createdAt}>{formatTime(event.createdAt)}</time></div>)}</div>}
      </section>
    </>}
  </>;
}

function FeaturedManager({ onChanged }: { onChanged: () => void }) {
  const sections = [
    ["hero", "Featured"], ["editors-picks", "Editor’s Picks"], ["new-releases", "New Releases"],
    ["recently-updated", "Recently Updated"], ["popular", "Popular"],
  ] as const;
  const [section, setSection] = useState<string>("hero");
  const [apps, setApps] = useState<AdminApp[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [allApps, entries] = await Promise.all([
        apiRequest<AdminApp[]>("/api/v1/admin/apps"),
        apiRequest<FeaturedEntry[]>("/api/v1/admin/featured"),
      ]);
      setApps(allApps.filter((item) => item.published));
      setSelected(entries.filter((item) => item.sectionKey === section).sort((a, b) => a.ordinal - b.ordinal).map((item) => item.appId));
      setError("");
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Featured content could not be loaded."); }
  }, [section]);
  useEffect(() => { void load(); }, [load]);

  function toggle(id: string) {
    setSelected((current) => current.includes(id) ? current.filter((value) => value !== id) : [...current, id]);
  }
  function move(id: string, offset: -1 | 1) {
    setSelected((current) => {
      const list = [...current]; const index = list.indexOf(id); const target = index + offset;
      if (index < 0 || target < 0 || target >= list.length) return current;
      [list[index], list[target]] = [list[target]!, list[index]!]; return list;
    });
  }
  async function save() {
    setBusy(true); setMessage(""); setError("");
    try {
      await apiRequest(`/api/v1/admin/featured/${section}`, { method: "PUT", body: JSON.stringify({ appIds: selected }) });
      setMessage("Featured order saved."); await load(); onChanged();
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Featured order could not be saved."); }
    finally { setBusy(false); }
  }

  const label = sections.find(([key]) => key === section)?.[1] ?? "Featured";
  return <><div className="page-heading compact"><p className="eyebrow">TODAY EDITORIAL</p><h1>Featured</h1><p className="muted">Choose published apps and set the order for each collection.</p></div>
    {error && <p className="notice error" role="alert">{error}</p>}{message && <p className="notice success" role="status">{message}</p>}
    <section className="work-card featured-editor"><div className="section-title"><div><p className="eyebrow">COLLECTION</p><h2>{label}</h2></div><button className="primary" onClick={() => void save()} disabled={busy}>{busy ? "Saving…" : "Save order"}</button></div>
      <div className="segmented">{sections.map(([key, title]) => <button key={key} className={section === key ? "selected" : ""} onClick={() => setSection(key)}>{title}</button>)}</div>
      <div className="featured-layout"><div><h3>Published apps</h3>{apps.length === 0 ? <p className="muted">Publish an app before adding it to a collection.</p> : apps.map((app) => <label key={app.id} className="select-app">
        <input type="checkbox" checked={selected.includes(app.id)} onChange={() => toggle(app.id)} /><span><strong>{app.name}</strong><small>{app.developer} · {app.bundleIdentifier}</small></span>
      </label>)}</div>
        <div><h3>Display order <small>{selected.length}/50</small></h3>{selected.length === 0 ? <div className="drop-empty">No apps selected for this section.</div> : selected.map((id, index) => {
          const app = apps.find((item) => item.id === id);
          return app && <div className="order-row" key={id}><span className="order-number">{index + 1}</span><div><strong>{app.name}</strong><small>{app.category}</small></div>
            <button aria-label="Move earlier" disabled={index === 0} onClick={() => move(id, -1)}>↑</button><button aria-label="Move later" disabled={index === selected.length - 1} onClick={() => move(id, 1)}>↓</button></div>;
        })}</div></div>
      <p className="fine-print">Only apps with a published release can appear here. Public Today collections update immediately after saving.</p>
    </section></>;
}

function StoragePage({ dashboard }: { dashboard: AdminDashboardData | null }) {
  return <><div className="page-heading compact"><p className="eyebrow">OBJECT STORAGE</p><h1>Storage</h1><p className="muted">Visibility into published package storage and the upload pipeline.</p></div>
    <div className="metric-grid"><Metric label="Published packages" value={formatBytes(dashboard?.storageBytes ?? 0)} caption="Sum of published IPA sizes in D1" icon="▤" />
      <Metric label="Active uploads" value={String(dashboard?.pendingUploads ?? 0)} caption="Private staging and review" icon="↥" /></div>
    <section className="work-card"><h2>Retention</h2><p className="muted">Private staging objects are deleted after publish or rejection. Expired staging cleanup is performed by the configured maintenance process; this panel does not claim unmeasured R2 totals.</p>
      <p className="fine-print">Published asset bytes are not included because R2 object storage is not queried as a billing meter.</p></section>
  </>;
}

function Metric({ label, value, caption, icon }: { label: string; value: string; caption: string; icon: string }) {
  return <article className="metric-card"><div className="metric-top"><span>{label}</span><span className="mini-icon">{icon}</span></div><strong>{value}</strong><small>{caption}</small></article>;
}

function humanize(value: string) { return value.replace(/[._]/gu, " ").replace(/\b\w/gu, (letter) => letter.toUpperCase()); }
function formatTime(value: string) {
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date) : value;
}
