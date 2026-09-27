import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { QRCodeSVG } from "qrcode.react";
import { Activity, AlertTriangle, ArrowDownToLine, Check, ChevronRight, CircleHelp, Copy, FileKey2, Fingerprint, KeyRound, Link2, LockKeyhole, PackageCheck, RefreshCw, ShieldCheck, Smartphone, Usb, X } from "lucide-react";

type Device = {
  udid: string;
  name: string;
  productType?: string;
  productVersion?: string;
  buildVersion?: string;
  developerMode?: boolean;
  trusted: boolean;
};

type Snapshot = {
  devices: Device[];
  deviceServiceAvailable: boolean;
  deviceServiceError?: string | null;
  signing: {
    configured: boolean;
    identityLabel?: string | null;
    certificateExpiresAt?: string | null;
    provisioningExpiresAt?: string | null;
    teamId?: string | null;
    accountKind?: string | null;
    limitation?: string | null;
  };
  paired: boolean;
  pairedPhoneLastSeenAt?: string | null;
  localEndpoint?: string | null;
  apiError?: string | null;
};

type PairingOffer = {
  payload: string;
  code: string;
  endpoint: string;
  certificateSha256: string;
  expiresAt: string;
};

type HistoryItem = {
  bundleIdentifier: string;
  version: string;
  build: string;
  udid: string;
  installedAt: string;
  provisioningExpiresAt?: string | null;
};

type Section = "overview" | "setup" | "signing";

const formatDate = (value?: string | null) => value ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(new Date(value)) : "Not reported";
const masked = (value: string) => `${value.slice(0, 8)} ···· ${value.slice(-6)}`;

export default function App() {
  const [section, setSection] = useState<Section>("overview");
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [history, setHistory] = useState<HistoryItem[]>([]);
  const [offer, setOffer] = useState<PairingOffer | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const refreshInFlight = useRef(false);

  const refresh = useCallback(async () => {
    if (refreshInFlight.current) return;
    refreshInFlight.current = true;
    try {
      const [nextSnapshot, nextHistory] = await Promise.all([
        invoke<Snapshot>("get_dashboard_snapshot"),
        invoke<HistoryItem[]>("get_install_history"),
      ]);
      setSnapshot(nextSnapshot);
      setHistory(nextHistory);
    } catch (error) {
      setNotice(String(error));
    } finally {
      refreshInFlight.current = false;
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 5000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const currentTitle = useMemo(() => ({ overview: "Overview", setup: "Setup", signing: "Signing" })[section], [section]);

  async function createPairing() {
    setBusy(true);
    setNotice(null);
    try {
      setOffer(await invoke<PairingOffer>("create_pairing_qr"));
      await refresh();
    } catch (error) {
      setNotice(String(error));
    } finally {
      setBusy(false);
    }
  }

  async function forgetPhone() {
    setBusy(true);
    try {
      await invoke("forget_paired_phone");
      setOffer(null);
      await refresh();
      setNotice("The paired phone token was removed from Windows Credential Manager.");
    } catch (error) {
      setNotice(String(error));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="shell">
      <aside className="rail">
        <div className="brand-lockup">
          <div className="brand-mark"><span>D</span></div>
          <div><strong>DreyzeStore</strong><small>Companion</small></div>
        </div>
        <div className="rail-label">WORKSPACE</div>
        <nav className="nav-list" aria-label="Main navigation">
          <NavItem active={section === "overview"} icon={<Activity size={17} />} label="Overview" onClick={() => setSection("overview")} />
          <NavItem active={section === "setup"} icon={<Smartphone size={17} />} label="Connect iPhone" onClick={() => setSection("setup")} />
          <NavItem active={section === "signing"} icon={<FileKey2 size={17} />} label="Apple Signing" onClick={() => setSection("signing")} />
        </nav>
        <div className="rail-spacer" />
        <div className="rail-help">
          <div className="help-icon"><CircleHelp size={17} /></div>
          <div><strong>Need a hand?</strong><span>Open the setup guide</span></div>
          <ChevronRight size={15} />
        </div>
        <div className="rail-footer"><span className="live-dot" /> Local service running <span className="version-tag">0.1.0</span></div>
      </aside>

      <main className="main-area">
        <header className="topbar">
          <div className="breadcrumbs"><span>Companion</span><ChevronRight size={14} /><strong>{currentTitle}</strong></div>
          <div className="top-actions">
            <div className="secure-indicator"><LockKeyhole size={14} /><span>Local only</span></div>
            <button className="icon-button" onClick={() => void refresh()} aria-label="Refresh status"><RefreshCw size={16} /></button>
            <div className="profile-avatar" aria-label="DreyzeStore Companion">D</div>
          </div>
        </header>

        {notice && <div className="notice" role="status"><AlertTriangle size={16} /><span>{notice}</span><button onClick={() => setNotice(null)} aria-label="Dismiss notice"><X size={14} /></button></div>}

        {section === "overview" && <Overview
          snapshot={snapshot}
          history={history}
          onConnect={() => setSection("setup")}
          onSigning={() => setSection("signing")}
          onPair={createPairing}
          busy={busy}
        />}
        {section === "setup" && <Setup
          snapshot={snapshot}
          offer={offer}
          busy={busy}
          onPair={createPairing}
          onForget={forgetPhone}
          onCopy={async (value) => { await navigator.clipboard.writeText(value); setNotice("Copied to clipboard."); }}
        />}
        {section === "signing" && <Signing snapshot={snapshot} onChanged={refresh} onNotice={setNotice} />}
      </main>
    </div>
  );
}

function NavItem({ active, icon, label, onClick }: { active: boolean; icon: ReactNode; label: string; onClick: () => void }) {
  return <button className={`nav-item ${active ? "active" : ""}`} onClick={onClick}>{icon}<span>{label}</span>{active && <i />}</button>;
}

function Overview({ snapshot, history, onConnect, onSigning, onPair, busy }: {
  snapshot: Snapshot | null; history: HistoryItem[]; onConnect: () => void; onSigning: () => void; onPair: () => void; busy: boolean;
}) {
  const device = snapshot?.devices[0];
  return <div className="page-content">
    <div className="page-heading">
      <div><div className="eyebrow">{new Intl.DateTimeFormat(undefined, { weekday: "long", month: "long", day: "numeric" }).format(new Date()).toUpperCase()}</div><h1>Good to see you.</h1><p>Your iPhone setup, signing identity, and DreyzeStore connection in one place.</p></div>
      <button className="primary-button" onClick={onConnect}><Usb size={16} /> Set up iPhone <ChevronRight size={15} /></button>
    </div>

    <div className="hero-panel">
      <div className="hero-copy">
        <div className="eyebrow hero-eyebrow">DEVICE STATUS</div>
        {device ? <><h2>{device.name}</h2><p>{[device.productType, device.productVersion ? `iOS ${device.productVersion}` : null].filter(Boolean).join(" · ") || "Connected over USB"}</p></> : <><h2>Connect your iPhone</h2><p>Connect by USB, unlock the device, then tap Trust when iOS asks.</p></>}
        <div className="hero-status-row"><StatusPill ok={Boolean(device)} label={device ? "USB connected" : "Not connected"} /><StatusPill ok={device?.trusted ?? false} label={device?.trusted ? "Trusted" : "Trust pending"} /><StatusPill ok={device?.developerMode === true} neutral={device?.developerMode == null} label={device?.developerMode === true ? "Developer Mode on" : device?.developerMode === false ? "Developer Mode off" : "Developer Mode unknown"} /></div>
      </div>
      <div className={`device-illustration ${device ? "connected" : ""}`}><div className="device-glow" /><div className="phone-frame"><div className="phone-notch" /><div className="phone-screen"><div className="phone-status"><span>9:41</span><span>●●●</span></div><div className="phone-mark">D</div><div className="phone-caption">{device ? "Connected" : "Waiting for iPhone"}</div><div className="phone-app-dots"><i /><i /><i /></div></div></div><div className="signal-ring ring-one" /><div className="signal-ring ring-two" /></div>
      <div className="hero-bottom"><span><ShieldCheck size={15} /> Requests stay on your local network</span>{device && <span className="masked-udid">{masked(device.udid)}</span>}</div>
    </div>

    <section className="section-block">
      <div className="section-title"><div><div className="eyebrow">READY CHECK</div><h2>Installation prerequisites</h2></div><button className="text-button" onClick={onConnect}>View setup <ChevronRight size={14} /></button></div>
      <div className="check-grid">
        <CheckCard icon={<Usb size={18} />} title="USB connection" description={device ? "iPhone is visible to the device service." : snapshot?.deviceServiceAvailable ? "Connect an unlocked iPhone with a data cable." : "Apple device support is not available."} state={device ? "complete" : "pending"} />
        <CheckCard icon={<Fingerprint size={18} />} title="Trust this PC" description={device?.trusted ? "Pairing record is available on this computer." : "Tap Trust on the iPhone and enter its passcode."} state={device?.trusted ? "complete" : "pending"} />
        <CheckCard icon={<Smartphone size={18} />} title="Developer Mode" description={device?.developerMode === true ? "Enabled on the connected device." : device?.developerMode === false ? "Enable it in Settings → Privacy & Security." : "Status cannot be queried yet; check Settings on iPhone."} state={device?.developerMode === true ? "complete" : "pending"} />
        <CheckCard icon={<KeyRound size={18} />} title="Apple signing" description={snapshot?.signing.configured ? "A local development identity is configured." : "Import a device-matched certificate and profile."} state={snapshot?.signing.configured ? "complete" : "pending"} action={!snapshot?.signing.configured ? onSigning : undefined} />
      </div>
    </section>

    <div className="two-column">
      <section className="section-block card-section">
        <div className="section-title compact"><div><div className="eyebrow">DREYZESTORE</div><h2>iPhone pairing</h2></div><StatusPill ok={snapshot?.paired ?? false} label={snapshot?.paired ? "Paired" : "Not paired"} /></div>
        <p className="section-description">Pair once over a pinned local TLS connection. The store backend never receives your Apple identity or pairing token.</p>
        <button className="secondary-button" onClick={onPair} disabled={busy}><Link2 size={16} /> {busy ? "Preparing…" : "Show pairing code"}</button>
      </section>
      <section className="section-block card-section signing-summary">
        <div className="section-title compact"><div><div className="eyebrow">SIGNING IDENTITY</div><h2>{snapshot?.signing.configured ? "Ready to sign" : "Not configured"}</h2></div><div className={`status-icon ${snapshot?.signing.configured ? "ok" : ""}`}>{snapshot?.signing.configured ? <Check size={16} /> : <FileKey2 size={16} />}</div></div>
        <p className="section-description">{snapshot?.signing.configured ? snapshot.signing.limitation : "Your .p12 and mobileprovision stay on this Windows PC."}</p>
        <button className="text-button" onClick={onSigning}>Manage signing <ChevronRight size={14} /></button>
      </section>
    </div>

    <section className="section-block">
      <div className="section-title"><div><div className="eyebrow">ACTIVITY</div><h2>Recent installs</h2></div><span className="activity-count">{history.length} total</span></div>
      <div className="activity-card">
        {history.length ? history.slice(0, 5).map((item) => <div className="activity-row" key={`${item.bundleIdentifier}:${item.version}`}>
          <div className="activity-app-icon"><PackageCheck size={18} /></div><div className="activity-app"><strong>{item.bundleIdentifier}</strong><span>Version {item.version} ({item.build})</span></div><StatusPill ok label="Confirmed" /><time>{formatDate(item.installedAt)}</time>
        </div>) : <div className="empty-activity"><div className="empty-icon"><ArrowDownToLine size={20} /></div><strong>No installs yet</strong><span>Once an installation is confirmed by the iPhone, it will appear here.</span></div>}
      </div>
    </section>
    {snapshot?.deviceServiceError && <p className="inline-warning"><AlertTriangle size={14} /> {snapshot.deviceServiceError}</p>}
  </div>;
}

function Setup({ snapshot, offer, busy, onPair, onForget, onCopy }: {
  snapshot: Snapshot | null; offer: PairingOffer | null; busy: boolean; onPair: () => void; onForget: () => void; onCopy: (value: string) => void;
}) {
  const device = snapshot?.devices[0];
  return <div className="page-content narrow-content">
    <div className="page-heading"><div><div className="eyebrow">FIRST-TIME SETUP</div><h1>Connect your iPhone.</h1><p>These steps are required by iOS and can’t be completed silently by the companion.</p></div></div>
    <div className="wizard-card">
      <SetupStep number="01" icon={<Usb size={17} />} title="Connect over USB" detail="Use a data cable, unlock the iPhone, then tap Trust This Computer when prompted." done={Boolean(device)} />
      <SetupStep number="02" icon={<Smartphone size={17} />} title="Enable Developer Mode" detail="On the iPhone open Settings → Privacy & Security → Developer Mode. Confirm the restart and passcode prompt." done={device?.developerMode === true} />
      <SetupStep number="03" icon={<FileKey2 size={17} />} title="Add a signing identity" detail="Import an Apple Development .p12 and a profile that includes this iPhone’s UDID and the app bundle identifier." done={snapshot?.signing.configured ?? false} />
      <SetupStep number="04" icon={<Link2 size={17} />} title="Pair DreyzeStore" detail="Scan the one-time QR code from DreyzeStore on iPhone → Settings → Connect Computer." done={snapshot?.paired ?? false} />
      <SetupStep number="05" icon={<Check size={17} />} title="Test the local connection" detail={snapshot?.pairedPhoneLastSeenAt ? `The paired iPhone last reached this PC ${formatDate(snapshot.pairedPhoneLastSeenAt)}.` : "After pairing, DreyzeStore checks device and signing status through this local connection."} done={Boolean(snapshot?.pairedPhoneLastSeenAt)} last />
    </div>
    <div className="pair-card">
      <div className="pair-card-copy"><div className="eyebrow">PAIR THIS PHONE</div><h2>{snapshot?.paired ? "A phone is paired" : "Create a one-time code"}</h2><p>Only the phone holding the pairing token can call this companion. The token is stored in iOS Keychain and Windows Credential Manager.</p>
        {snapshot?.paired ? <button className="danger-text-button" onClick={onForget}>Forget paired phone</button> : <button className="primary-button" disabled={busy || !snapshot?.localEndpoint} onClick={onPair}><Link2 size={16} /> {busy ? "Preparing…" : "Generate QR code"}</button>}
      </div>
      {offer && <div className="pair-code-panel"><div className="qr-surface"><QRCodeSVG value={offer.payload} size={184} bgColor="#ffffff" fgColor="#1a2230" level="M" includeMargin /></div><div className="pair-code-label">ONE-TIME CODE</div><div className="pair-code">{offer.code}</div><div className="pair-expiry">Expires {new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(new Date(offer.expiresAt))}</div><button className="copy-button" onClick={() => onCopy(offer.code)}><Copy size={14} /> Copy code</button></div>}
    </div>
    <div className="notice-card"><Usb size={17} /><p><strong>Windows device prerequisites.</strong> Companion uses the classic iTunes installer’s Apple Mobile Device Service and the separately installed <code>pymobiledevice3</code> command. It does not bundle that GPL-licensed device service. Install the classic iTunes package and run <code>python -m pip install -U pymobiledevice3</code>, then restart Companion.</p></div>
    <div className="notice-card"><ShieldCheck size={17} /><p><strong>Local trust boundary.</strong> This API binds only to the selected private LAN address, uses a certificate pin shown in the QR, requires a one-time pairing code, and rejects timestamped request replays. Don’t share the QR code.</p></div>
  </div>;
}

function Signing({ snapshot, onChanged, onNotice }: { snapshot: Snapshot | null; onChanged: () => Promise<void>; onNotice: (value: string) => void }) {
  const [p12Path, setP12Path] = useState("");
  const [profilePath, setProfilePath] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);

  async function chooseP12() {
    const value = await open({ multiple: false, filters: [{ name: "PKCS#12 signing identity", extensions: ["p12", "pfx"] }] });
    if (typeof value === "string") setP12Path(value);
  }
  async function chooseProfile() {
    const value = await open({ multiple: false, filters: [{ name: "Provisioning profile", extensions: ["mobileprovision", "provisionprofile"] }] });
    if (typeof value === "string") setProfilePath(value);
  }
  async function save() {
    if (!p12Path || !profilePath || !password) { onNotice("Choose both signing files and enter the P12 password."); return; }
    setBusy(true);
    try {
      await invoke("import_signing_identity", { p12Path, profilePath, password });
      setPassword(""); setP12Path(""); setProfilePath("");
      onNotice("Signing files were encrypted with DPAPI and the P12 password was saved in Windows Credential Manager.");
      await onChanged();
    } catch (error) { onNotice(String(error)); }
    finally { setBusy(false); }
  }
  async function remove() {
    if (!window.confirm("Remove the local signing identity from this PC?")) return;
    try { await invoke("clear_signing_identity"); await onChanged(); onNotice("Local signing identity removed."); }
    catch (error) { onNotice(String(error)); }
  }

  return <div className="page-content narrow-content">
    <div className="page-heading"><div><div className="eyebrow">APPLE DEVELOPMENT</div><h1>Signing identity.</h1><p>All signing stays on this computer. DreyzeStore never asks for an Apple ID password or 2FA code.</p></div></div>
    <div className="signing-hero"><div className="signing-symbol"><FileKey2 size={24} /></div><div><div className="eyebrow">CURRENT STATUS</div><h2>{snapshot?.signing.configured ? "Identity imported" : "No signing identity"}</h2><p>{snapshot?.signing.configured ? snapshot.signing.limitation : "Import an Apple Development certificate and a provisioning profile created for your device."}</p>{snapshot?.signing.provisioningExpiresAt && <p>Provisioning profile expires {formatDate(snapshot.signing.provisioningExpiresAt)}.</p>}</div><span className={`status-dot ${snapshot?.signing.configured ? "good" : "muted"}`} /></div>
    <div className="form-card">
      <div className="section-title compact"><div><div className="eyebrow">LOCAL FILES</div><h2>Import certificate & profile</h2></div></div>
      <FileChoice label="Apple Development identity" detail="Encrypted .p12 or .pfx" value={p12Path} action={chooseP12} />
      <FileChoice label="Provisioning profile" detail="Must include this device’s UDID and matching App ID" value={profilePath} action={chooseProfile} />
      <label className="field-label" htmlFor="p12-password">P12 password</label>
      <input id="p12-password" type="password" autoComplete="new-password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Used locally to open the identity" />
      <div className="form-footnote"><LockKeyhole size={14} /><span>The encrypted P12 and profile are protected by Windows DPAPI. The password is kept in Windows Credential Manager and sent to the signer through a private stdin pipe, never in process arguments or logs.</span></div>
      <div className="form-actions"><button className="secondary-button" onClick={() => { setPassword(""); setP12Path(""); setProfilePath(""); }}>Clear fields</button><button className="primary-button" onClick={() => void save()} disabled={busy}>{busy ? "Saving…" : "Save signing identity"}<ChevronRight size={15} /></button></div>
      {snapshot?.signing.configured && <button className="danger-text-button remove-identity" onClick={() => void remove()}>Remove saved identity</button>}
    </div>
    <div className="limitations-card"><div className="limitations-title"><AlertTriangle size={16} /><strong>Account and device limits</strong></div><ul><li>Free Apple Personal Team profiles expire after 7 days and Apple’s documented workflow uses Xcode on macOS to provision them. This Windows flow does not automate free-account provisioning.</li><li>A paid Apple Developer membership can manage devices, certificates, and development profiles through Apple’s developer portal. Membership is optional; this app doesn’t purchase it.</li><li>Developer Mode must be enabled by the iPhone owner. A provisioning profile must include the connected UDID and matching bundle ID.</li><li>Imported profiles may expire or be revoked. The companion reports profile expiry when it can parse the file; it never promises permanent signing.</li></ul></div>
  </div>;
}

function StatusPill({ ok, label, neutral = false }: { ok: boolean; label: string; neutral?: boolean }) {
  return <span className={`status-pill ${ok ? "ok" : neutral ? "neutral" : "pending"}`}><i />{label}</span>;
}

function CheckCard({ icon, title, description, state, action }: { icon: ReactNode; title: string; description: string; state: "complete" | "pending"; action?: () => void }) {
  return <div className="check-card"><div className={`check-icon ${state}`}>{icon}</div><div className="check-copy"><strong>{title}</strong><span>{description}</span>{action && <button className="inline-link" onClick={action}>Configure <ChevronRight size={13} /></button>}</div><div className={`check-mark ${state}`}>{state === "complete" ? <Check size={13} /> : <span />}</div></div>;
}

function SetupStep({ number, icon, title, detail, done, last = false }: { number: string; icon: ReactNode; title: string; detail: string; done: boolean; last?: boolean }) {
  return <div className={`setup-step ${last ? "last" : ""}`}><div className={`step-number ${done ? "done" : ""}`}>{done ? <Check size={14} /> : number}</div><div className="step-icon">{icon}</div><div className="step-copy"><strong>{title}</strong><span>{detail}</span></div><StatusPill ok={done} label={done ? "Complete" : "Pending"} /></div>;
}

function FileChoice({ label, detail, value, action }: { label: string; detail: string; value: string; action: () => void }) {
  return <div className="file-choice"><div className="file-choice-icon"><FileKey2 size={16} /></div><div className="file-choice-copy"><strong>{label}</strong><span>{value || detail}</span></div><button className="secondary-button small" onClick={() => void action()}>{value ? "Change" : "Choose file"}</button></div>;
}
