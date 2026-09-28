import { invoke } from "@tauri-apps/api/core";
import { getVersion } from "@tauri-apps/api/app";
import { listen } from "@tauri-apps/api/event";
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

type ReadinessCheck = { status: "pass" | "fail" | "unknown"; details: string };
type DeviceReadiness = {
  runAt: string;
  appleMobileDeviceService: ReadinessCheck;
  usbConnection: ReadinessCheck;
  trust: ReadinessCheck;
  developerMode: ReadinessCheck;
  pymobiledevice3: ReadinessCheck;
  signingIdentity: ReadinessCheck;
  provisioning: ReadinessCheck;
  dreyzePairing: ReadinessCheck;
};
type AppleTeam = { teamId: string; name: string; teamType: string };
type AppleAccountStatus = {
  connected: boolean;
  email?: string | null;
  selectedTeamId?: string | null;
  anisetteUrl?: string | null;
  state: string;
  limitation?: string | null;
};
type TwoFactorChallenge = {
  retryMessage?: string | null;
  unknown: boolean;
  sms: boolean;
  numbers: { id: number; lastTwoDigits: string }[];
  selectedNumberId?: number | null;
};
type TestPackageMetadata = {
  bundleIdentifier: string;
  version: string;
  build: string;
  size: number;
  sha256: string;
  minimumOSVersion?: string | null;
  appName?: string | null;
};
type TestInstallation = {
  bundleIdentifier: string;
  version: string;
  build: string;
  sha256: string;
  size: number;
  udid: string;
  teamIdentifier?: string | null;
  certificateExpiresAt?: string | null;
  provisioningExpiresAt?: string | null;
  installedAt: string;
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
function userFacingError(error: unknown) {
  const detail = String(error).toLowerCase();
  if (detail.includes("signing") || detail.includes("provision") || detail.includes("certificate")) return "Signing setup is not ready. Check the Apple Signing page and run diagnostics.";
  if (detail.includes("device") || detail.includes("usb") || detail.includes("trust") || detail.includes("developer mode")) return "The iPhone is unavailable. Connect it over USB, unlock it, and check Trust and Developer Mode.";
  if (detail.includes("pair") || detail.includes("certificate pin") || detail.includes("unauthorized")) return "The paired connection could not be verified. Reconnect using the current one-time pairing code.";
  if (detail.includes("inventory") || detail.includes("installed app") || detail.includes("install")) return "Installation could not be confirmed. Reconnect the iPhone, run diagnostics, and refresh its inventory.";
  if (detail.includes("service") || detail.includes("pymobiledevice")) return "The Apple device service is unavailable. Check the setup requirements and run diagnostics.";
  return "The operation could not be completed. Run diagnostics and try again.";
}

export default function App() {
  const [section, setSection] = useState<Section>("overview");
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [history, setHistory] = useState<HistoryItem[]>([]);
  const [readiness, setReadiness] = useState<DeviceReadiness | null>(null);
  const [testInstallation, setTestInstallation] = useState<TestInstallation | null>(null);
  const [diagnosing, setDiagnosing] = useState(false);
  const [testingInstall, setTestingInstall] = useState(false);
  const [offer, setOffer] = useState<PairingOffer | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [appVersion, setAppVersion] = useState("0.9.0 RC1");
  const refreshInFlight = useRef(false);

  const refresh = useCallback(async () => {
    if (refreshInFlight.current) return;
    refreshInFlight.current = true;
    try {
      const [nextSnapshot, nextHistory, nextTestInstallation] = await Promise.all([
        invoke<Snapshot>("get_dashboard_snapshot"),
        invoke<HistoryItem[]>("get_install_history"),
        invoke<TestInstallation | null>("get_test_installation"),
      ]);
      setSnapshot(nextSnapshot);
      setHistory(nextHistory);
      setTestInstallation(nextTestInstallation);
    } catch (error) {
      setNotice(userFacingError(error));
    } finally {
      refreshInFlight.current = false;
    }
  }, []);

  useEffect(() => {
    void getVersion()
      .then((version) => setAppVersion(({ "0.9.0-1": "0.9.0 RC1", "0.9.0-2": "0.9.0 RC2" } as Record<string, string>)[version] ?? version))
      .catch(() => undefined);
    void refresh();
    const timer = window.setInterval(() => void refresh(), 30000);
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
      setNotice(userFacingError(error));
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
      setNotice(userFacingError(error));
    } finally {
      setBusy(false);
    }
  }

  async function runDiagnostics() {
    if (diagnosing) return;
    setDiagnosing(true);
    try {
      setReadiness(await invoke<DeviceReadiness>("get_device_readiness"));
    } catch (error) {
      setNotice(userFacingError(error));
    } finally {
      setDiagnosing(false);
    }
  }

  async function runTestInstallation() {
    if (testingInstall) return;
    const path = await open({ multiple: false, filters: [{ name: "DreyzeStore test IPA", extensions: ["ipa"] }] });
    if (typeof path !== "string") return;
    setTestingInstall(true);
    try {
      const metadata = await invoke<TestPackageMetadata>("inspect_test_package", { path });
      const size = `${(metadata.size / 1_048_576).toFixed(1)} MB`;
      const accepted = window.confirm(
        `Install and verify this authorized test app on the connected iPhone?\n\n${metadata.appName ?? metadata.bundleIdentifier}\n${metadata.bundleIdentifier}\nVersion ${metadata.version} (${metadata.build}) · ${size}\n\nOnly org.dreyzestore.test.* bundle IDs are accepted. The package is locally inspected, signed, installed, and confirmed through device inventory.`,
      );
      if (!accepted) return;
      const installed = await invoke<TestInstallation>("run_test_installation", { path });
      setTestInstallation(installed);
      await refresh();
      setNotice(`Test app ${installed.bundleIdentifier} ${installed.version} was confirmed in the iPhone inventory.`);
    } catch (error) {
      setNotice(userFacingError(error));
    } finally {
      setTestingInstall(false);
    }
  }

  async function removeTestInstallation() {
    if (!testInstallation || !window.confirm(`Remove the Companion test app ${testInstallation.bundleIdentifier} from the iPhone?`)) return;
    try {
      await invoke("uninstall_test_installation");
      setTestInstallation(null);
      await refresh();
      setNotice("The test app was removed and absence was confirmed in device inventory.");
    } catch (error) {
      setNotice(userFacingError(error));
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
        <div className="rail-footer"><span className="live-dot" /> Local service running <span className="version-tag">{appVersion}</span></div>
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
          onRefresh={refresh}
          onPair={createPairing}
          onForget={forgetPhone}
          onCopy={async (value) => { await navigator.clipboard.writeText(value); setNotice("Copied to clipboard."); }}
        />}
        {section === "signing" && <Signing
          snapshot={snapshot}
          readiness={readiness}
          diagnosing={diagnosing}
          testingInstall={testingInstall}
          testInstallation={testInstallation}
          onChanged={refresh}
          onNotice={setNotice}
          onDiagnostics={runDiagnostics}
          onTestInstall={runTestInstallation}
          onRemoveTestInstall={removeTestInstallation}
        />}
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

function Setup({ snapshot, offer, busy, onRefresh, onPair, onForget, onCopy }: {
  snapshot: Snapshot | null; offer: PairingOffer | null; busy: boolean; onRefresh: () => Promise<void>; onPair: () => void; onForget: () => void; onCopy: (value: string) => void;
}) {
  const device = snapshot?.devices[0];
  return <div className="page-content narrow-content">
    <div className="page-heading"><div><div className="eyebrow">FIRST-TIME SETUP</div><h1>Connect your iPhone.</h1><p>These steps are required by iOS and can’t be completed silently by the companion.</p></div><button className="secondary-button" onClick={() => void onRefresh()}><RefreshCw size={15} /> Check connection</button></div>
    <div className={`device-detection ${device ? "connected" : snapshot?.deviceServiceError ? "unavailable" : ""}`} role="status" aria-live="polite">
      <div className="device-detection-icon">{device ? <Check size={17} /> : snapshot?.deviceServiceError ? <AlertTriangle size={17} /> : <Usb size={17} />}</div>
      <div className="device-detection-copy">
        <strong>{device ? `${device.name} detected` : snapshot?.deviceServiceError ? "Couldn’t check for an iPhone" : snapshot ? "Waiting for a trusted iPhone" : "Checking for an iPhone…"}</strong>
        <span>{device
          ? [device.productType, device.productVersion ? `iOS ${device.productVersion}` : null].filter(Boolean).join(" · ") || "Connected over USB"
          : snapshot?.deviceServiceError
            ? "The Apple device bridge failed. Open Apple Signing → Run Diagnostics to see the specific cause."
            : "Unlock the iPhone and accept Trust This Computer. Then check the connection again."}</span>
      </div>
    </div>
    <div className="wizard-card">
      <SetupStep number="01" icon={<Usb size={17} />} title="Connect over USB" detail="Use a data cable, unlock the iPhone, then tap Trust This Computer when prompted." state={device ? "complete" : "pending"} />
      <SetupStep number="02" icon={<Smartphone size={17} />} title="Enable Developer Mode" detail={device?.developerMode === false ? "Developer Mode is reported off. Enable it in Settings → Privacy & Security → Developer Mode." : "Companion can’t read this setting reliably. Check Settings → Privacy & Security → Developer Mode directly; an unknown status does not mean it is off."} state={device?.developerMode === true ? "complete" : device?.developerMode === false ? "pending" : "unknown"} />
      <SetupStep number="03" icon={<FileKey2 size={17} />} title="Add a signing identity" detail="Import an Apple Development .p12 and a profile that includes this iPhone’s UDID and the app bundle identifier." state={snapshot?.signing.configured ? "complete" : "pending"} />
      <SetupStep number="04" icon={<Link2 size={17} />} title="Pair DreyzeStore" detail="Scan the one-time QR code from DreyzeStore on iPhone → Settings → Connect Computer." state={snapshot?.paired ? "complete" : "pending"} />
      <SetupStep number="05" icon={<Check size={17} />} title="Test the local connection" detail={snapshot?.pairedPhoneLastSeenAt ? `The paired iPhone last reached this PC ${formatDate(snapshot.pairedPhoneLastSeenAt)}.` : "After pairing, DreyzeStore checks device and signing status through this local connection."} state={snapshot?.pairedPhoneLastSeenAt ? "complete" : "pending"} last />
    </div>
    <div className="pair-card">
      <div className="pair-card-copy"><div className="eyebrow">PAIR THIS PHONE</div><h2>{snapshot?.paired ? "A phone is paired" : "Create a one-time code"}</h2><p>Only the phone holding the pairing token can call this companion. The token is stored in iOS Keychain and Windows Credential Manager.</p>
        {snapshot?.paired ? <button className="danger-text-button" onClick={onForget}>Forget paired phone</button> : <button className="primary-button" disabled={busy || !snapshot?.localEndpoint} onClick={onPair}><Link2 size={16} /> {busy ? "Preparing…" : "Generate QR code"}</button>}
      </div>
      {offer && <div className="pair-code-panel"><div className="qr-surface"><QRCodeSVG value={offer.payload} size={184} bgColor="#ffffff" fgColor="#1a2230" level="M" includeMargin /></div><div className="pair-code-label">ONE-TIME CODE</div><div className="pair-code">{offer.code}</div><div className="pair-expiry">Expires {new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(new Date(offer.expiresAt))}</div><button className="copy-button" onClick={() => onCopy(offer.code)}><Copy size={14} /> Copy code</button></div>}
    </div>
    {snapshot?.deviceServiceAvailable
      ? <div className="notice-card"><Usb size={17} /><p><strong>USB device bridge is responding.</strong> If the iPhone is not listed above, unlock it, accept Trust This Computer, then use Check connection. Developer Mode status is checked on the iPhone because the USB bridge does not report it.</p></div>
      : <div className="notice-card"><Usb size={17} /><p><strong>Windows device prerequisites.</strong> Companion uses the classic iTunes installer’s Apple Mobile Device Service and the separately installed <code>pymobiledevice3</code> command. It does not bundle that GPL-licensed device service. Install the classic iTunes package and run <code>python -m pip install -U pymobiledevice3</code>, then restart Companion.</p></div>}
    <div className="notice-card"><ShieldCheck size={17} /><p><strong>Local trust boundary.</strong> This API binds only to the selected private LAN address, uses a certificate pin shown in the QR, requires a one-time pairing code, and rejects timestamped request replays. Don’t share the QR code.</p></div>
  </div>;
}

function Signing({ snapshot, readiness, diagnosing, testingInstall, testInstallation, onChanged, onNotice, onDiagnostics, onTestInstall, onRemoveTestInstall }: {
  snapshot: Snapshot | null;
  readiness: DeviceReadiness | null;
  diagnosing: boolean;
  testingInstall: boolean;
  testInstallation: TestInstallation | null;
  onChanged: () => Promise<void>;
  onNotice: (value: string) => void;
  onDiagnostics: () => void;
  onTestInstall: () => void;
  onRemoveTestInstall: () => void;
}) {
  const [p12Path, setP12Path] = useState("");
  const [profilePath, setProfilePath] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [appleEmail, setAppleEmail] = useState("");
  const [applePassword, setApplePassword] = useState("");
  const [anisetteUrl, setAnisetteUrl] = useState("https://ani.stikstore.app");
  const [anisetteTrusted, setAnisetteTrusted] = useState(false);
  const [appleStatus, setAppleStatus] = useState<AppleAccountStatus | null>(null);
  const [appleTeams, setAppleTeams] = useState<AppleTeam[]>([]);
  const [appleBusy, setAppleBusy] = useState(false);
  const [forceAppleLogin, setForceAppleLogin] = useState(false);
  const [twoFactor, setTwoFactor] = useState<TwoFactorChallenge | null>(null);
  const [verificationCode, setVerificationCode] = useState("");
  const [registeredUdid, setRegisteredUdid] = useState<string | null>(null);
  const connectedDeviceKey = snapshot?.devices.filter((device) => device.trusted).map((device) => device.udid).join(",") ?? "";

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let disposed = false;
    void listen<TwoFactorChallenge>("apple-account-two-factor", (event) => setTwoFactor(event.payload))
      .then((stop) => { if (disposed) stop(); else unlisten = stop; });
    void (async () => {
      try {
        const status = await invoke<AppleAccountStatus>("get_apple_account_status");
        setAppleStatus(status);
        if (status.connected) {
          const teams = await invoke<AppleTeam[]>("list_apple_teams");
          setAppleTeams(teams);
          if (status.selectedTeamId && teams.some((team) => team.teamId === status.selectedTeamId)) setAppleStatus(status);
          else if (teams.length === 1) {
            const selected = await invoke<AppleAccountStatus>("select_apple_team", { teamId: teams[0].teamId });
            setAppleStatus(selected);
          }
        }
      } catch { /* Offline or expired Apple sessions remain a recoverable UI state. */ }
    })();
    return () => { disposed = true; unlisten?.(); };
  }, []);

  useEffect(() => {
    const device = snapshot?.devices.find((item) => item.trusted);
    if (!device || !appleStatus?.connected || !appleStatus.selectedTeamId) { setRegisteredUdid(null); return; }
    let cancelled = false;
    void invoke<boolean>("is_apple_device_registered", { udid: device.udid })
      .then((registered) => { if (!cancelled) setRegisteredUdid(registered ? device.udid : null); })
      .catch(() => { if (!cancelled) setRegisteredUdid(null); });
    return () => { cancelled = true; };
  }, [connectedDeviceKey, appleStatus?.connected, appleStatus?.selectedTeamId]);

  async function refreshAppleAccount() {
    const status = await invoke<AppleAccountStatus>("get_apple_account_status");
    setAppleStatus(status);
    if (status.connected) {
      const teams = await invoke<AppleTeam[]>("list_apple_teams");
      setAppleTeams(teams);
      if (!status.selectedTeamId && teams.length === 1) {
        setAppleStatus(await invoke<AppleAccountStatus>("select_apple_team", { teamId: teams[0].teamId }));
      }
    } else setAppleTeams([]);
  }

  async function signInWithApple() {
    if (!appleEmail.trim() || !applePassword || !anisetteTrusted) {
      onNotice("Enter your Apple Account, choose an anisette endpoint, and confirm that you trust its operator.");
      return;
    }
    setAppleBusy(true);
    try {
      const signIn = invoke<AppleAccountStatus>("begin_apple_account_login", {
        email: appleEmail, password: applePassword, anisetteUrl, anisetteTrustConfirmed: anisetteTrusted,
      });
      setApplePassword("");
      const status = await signIn;
      setAppleStatus(status);
      setTwoFactor(null);
      const teams = await invoke<AppleTeam[]>("list_apple_teams");
      setAppleTeams(teams);
      if (teams.length === 1) setAppleStatus(await invoke<AppleAccountStatus>("select_apple_team", { teamId: teams[0].teamId }));
      setForceAppleLogin(false);
      onNotice("Apple Account connected locally. Review and select a team, then register your iPhone.");
    } catch (error) {
      setApplePassword("");
      onNotice(userFacingError(error));
      try { await refreshAppleAccount(); } catch { /* keep current status */ }
    } finally { setAppleBusy(false); }
  }

  async function submitTwoFactor(action: string, code?: string, numberId?: number) {
    try {
      await invoke("submit_apple_two_factor", { action, code, numberId });
      setTwoFactor(null);
      setVerificationCode("");
    } catch (error) { onNotice(userFacingError(error)); }
  }

  async function registerDevice(device: Device) {
    const team = appleTeams.find((item) => item.teamId === appleStatus?.selectedTeamId);
    if (!team) { onNotice("Choose an Apple development team first."); return; }
    if (!window.confirm(`Register ${device.name} with team ${team.name} (${team.teamId})? Apple may count this toward the team’s device limit.`)) return;
    setAppleBusy(true);
    try {
      await invoke("register_apple_device", { teamId: team.teamId, udid: device.udid, confirmed: true });
      setRegisteredUdid(device.udid);
      onNotice("iPhone registration was confirmed by Apple.");
      await onChanged();
    } catch (error) { onNotice(userFacingError(error)); }
    finally { setAppleBusy(false); }
  }

  async function prepareAppleCertificate() {
    if (!registeredUdid) { onNotice("Connect and register a trusted iPhone first."); return; }
    if (!window.confirm("Create or reuse a development certificate for this Apple team? DreyzeStore will not revoke any existing certificate.")) return;
    setAppleBusy(true);
    try {
      await invoke("prepare_apple_signing_certificate", { udid: registeredUdid });
      onNotice("The local signing identity is ready. App IDs and provisioning profiles are created or reused when an app is signed.");
      await onChanged();
    } catch (error) { onNotice(userFacingError(error)); }
    finally { setAppleBusy(false); }
  }

  async function signOutApple() {
    if (!window.confirm("Sign out on this PC? This removes the saved Apple session but keeps the local private key and does not revoke your certificate or affect installed apps.")) return;
    setAppleBusy(true);
    try {
      await invoke("sign_out_apple_account");
      setAppleStatus(null); setAppleTeams([]); setRegisteredUdid(null); setApplePassword(""); setForceAppleLogin(false);
      onNotice("Apple session removed from this PC. The local signing key remains available if you sign in again.");
      await onChanged();
    } catch (error) { onNotice(userFacingError(error)); }
    finally { setAppleBusy(false); }
  }

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
      setP12Path(""); setProfilePath("");
      onNotice("Signing files were encrypted with DPAPI and the P12 password was saved in Windows Credential Manager.");
      await onChanged();
    } catch (error) { onNotice(userFacingError(error)); }
    finally { setPassword(""); setBusy(false); }
  }
  async function remove() {
    if (!window.confirm("Remove the local signing identity from this PC?")) return;
    try { await invoke("clear_signing_identity"); await onChanged(); onNotice("Local signing identity removed."); }
    catch (error) { onNotice(userFacingError(error)); }
  }

  return <div className="page-content narrow-content">
    <div className="page-heading"><div><div className="eyebrow">APPLE DEVELOPMENT</div><h1>Signing identity.</h1><p>Apple credentials are processed locally by DreyzeStore Companion. They are never sent to DreyzeStore servers.</p></div></div>
    <div className="signing-hero"><div className="signing-symbol"><FileKey2 size={24} /></div><div><div className="eyebrow">CURRENT STATUS</div><h2>{appleStatus?.connected ? "Apple Account connected" : snapshot?.signing.configured ? "Signing identity ready" : "Signing setup required"}</h2><p>{appleStatus?.connected ? `${appleStatus.email ?? "Apple Account"}${appleStatus.selectedTeamId ? ` · Team ${appleStatus.selectedTeamId}` : " · Choose a team"}` : snapshot?.signing.limitation ?? "Sign in with an Apple Account or import an existing development identity."}</p><div className="signing-facts"><span><strong>Team</strong>{appleStatus?.selectedTeamId ?? snapshot?.signing.teamId ?? "Not selected"}</span><span><strong>Certificate</strong>{snapshot?.signing.certificateExpiresAt ? expirySummary(snapshot.signing.certificateExpiresAt) : "Not prepared"}</span><span><strong>Device</strong>{registeredUdid ? "Registered" : "Not registered"}</span></div></div><span className={`status-dot ${snapshot?.signing.configured ? "good" : "muted"}`} /></div>
    <section className="form-card onboarding-card">
      <div className="section-title compact"><div><div className="eyebrow">APPLE SIGNING SETUP</div><h2>Choose a supported setup path</h2></div></div>
      <div className="onboarding-option"><span className="option-badge">A</span><div><strong>Sign in with Apple Account</strong><p>Windows provisioning uses an unofficial, reverse-engineered Apple service protocol through the open-source isideload library. Apple does not document or support this Windows workflow; account/device eligibility and iOS acceptance can vary.</p></div></div>
      <div className="onboarding-option"><span className="option-badge">B</span><div><strong>Import existing signing files</strong><p>Advanced fallback for an Apple Development .p12 and matching .mobileprovision. The password remains in Windows Credential Manager and imported files are DPAPI-protected.</p></div></div>
    </section>
    <section className="form-card apple-account-card">
      <div className="section-title compact"><div><div className="eyebrow">LOCAL APPLE ACCOUNT</div><h2>{appleStatus?.connected ? "Account and team" : "Connect an Apple Account"}</h2></div>{appleStatus?.connected && <span className="status-pill ok"><i />Connected</span>}</div>
      {appleStatus?.connected && !forceAppleLogin ? <>
        <div className="account-summary"><strong>{appleStatus.email}</strong><span>{appleStatus.anisetteUrl ? `Anisette: ${appleStatus.anisetteUrl}` : "Anisette endpoint not reported"}</span></div>
        {appleTeams.length > 1 && <label className="field-label" htmlFor="apple-team">Development team</label>}
        {appleTeams.length > 1 && <select id="apple-team" value={appleStatus.selectedTeamId ?? ""} onChange={async (event) => { setAppleBusy(true); try { setAppleStatus(await invoke<AppleAccountStatus>("select_apple_team", { teamId: event.target.value })); } catch (error) { onNotice(userFacingError(error)); } finally { setAppleBusy(false); } }} disabled={appleBusy}>
          <option value="" disabled>Select a team</option>{appleTeams.map((team) => <option key={team.teamId} value={team.teamId}>{team.name} · {team.teamType} · {team.teamId}</option>)}
        </select>}
        {appleStatus.selectedTeamId && <div className="apple-setup-steps">
          {snapshot?.devices.filter((device) => device.trusted).map((device) => <div className="file-choice" key={device.udid}><div className="file-choice-icon"><Smartphone size={16} /></div><div className="file-choice-copy"><strong>{device.name}</strong><span>{device.productType ?? "iPhone"} · {registeredUdid === device.udid ? "Registered with this team" : device.udid}</span></div>{registeredUdid === device.udid ? <span className="status-pill ok"><i />Registered</span> : <button className="secondary-button small" disabled={appleBusy} onClick={() => void registerDevice(device)}>Register iPhone</button>}</div>)}
          {registeredUdid && <div className="certificate-action"><div><strong>Development certificate</strong><span>{snapshot?.signing.certificateExpiresAt ? expirySummary(snapshot.signing.certificateExpiresAt) : "Private key stays in Windows Credential Manager."}</span></div><button className="primary-button" disabled={appleBusy} onClick={() => void prepareAppleCertificate()}>{appleBusy ? "Preparing…" : snapshot?.signing.configured ? "Check certificate" : "Prepare signing"}<ChevronRight size={14} /></button></div>}
        </div>}
        <div className="form-actions"><button className="secondary-button" disabled={appleBusy} onClick={() => { void refreshAppleAccount(); }}>Refresh teams</button><button className="secondary-button" disabled={appleBusy} onClick={() => setForceAppleLogin(true)}>Reauthenticate</button><button className="danger-text-button" disabled={appleBusy} onClick={() => void signOutApple()}>Sign out</button></div>
      </> : <>
        <p className="section-description">Your Apple Account credentials are processed locally by DreyzeStore Companion and are sent directly to Apple for authentication. They are not sent to DreyzeStore servers, Cloudflare, analytics, or the anisette provider.</p>
        <label className="field-label" htmlFor="apple-email">Apple Account email</label><input id="apple-email" type="email" autoComplete="username" value={appleEmail} onChange={(event) => setAppleEmail(event.target.value)} placeholder="name@example.com" disabled={appleBusy} />
        <label className="field-label" htmlFor="apple-password">Apple Account password</label><input id="apple-password" type="password" autoComplete="current-password" value={applePassword} onChange={(event) => setApplePassword(event.target.value)} placeholder="Used only for this sign-in" disabled={appleBusy} />
        <label className="field-label" htmlFor="anisette-url">Anisette v3 HTTPS endpoint</label><input id="anisette-url" type="url" value={anisetteUrl} onChange={(event) => { setAnisetteUrl(event.target.value); setAnisetteTrusted(false); }} disabled={appleBusy} />
        <div className="form-footnote"><LockKeyhole size={14} /><span>The selected anisette operator receives ADI/an­isette provisioning data required by Apple’s authentication flow. It does not receive your Apple email, password, 2FA code, or reusable Apple session. Choose an operator you trust or your own HTTPS service.</span></div>
        <label className="trust-checkbox"><input type="checkbox" checked={anisetteTrusted} onChange={(event) => setAnisetteTrusted(event.target.checked)} disabled={appleBusy} /><span>I trust the operator of this anisette endpoint to process ADI/an­isette data.</span></label>
        {twoFactor && <div className="two-factor-panel" role="dialog" aria-labelledby="two-factor-title"><div><strong id="two-factor-title">Apple verification required</strong><span>Enter the code Apple sent to your trusted device or number. The code is used once and is not saved.</span>{twoFactor.retryMessage && <small>{twoFactor.retryMessage}</small>}</div>
          <label className="field-label" htmlFor="apple-verification-code">Verification code</label><input id="apple-verification-code" inputMode="numeric" autoComplete="one-time-code" maxLength={10} value={verificationCode} onChange={(event) => setVerificationCode(event.target.value.replace(/\D/g, ""))} />
          <div className="form-actions"><button className="secondary-button" onClick={() => void submitTwoFactor("cancel")}>Cancel</button>{twoFactor.numbers.map((number) => <button key={number.id} className="secondary-button" onClick={() => void submitTwoFactor("sendSms", undefined, number.id)}>Text ending {number.lastTwoDigits}</button>)}<button className="primary-button" disabled={!verificationCode || appleBusy} onClick={() => void submitTwoFactor("submitCode", verificationCode)}>Verify</button></div>
          <button className="inline-link" onClick={() => void submitTwoFactor(twoFactor.sms ? "resendCode" : "sendToDevices")}>{twoFactor.sms ? "Resend code" : "Send a code to trusted devices"}</button>
        </div>}
        <div className="form-actions"><button className="primary-button" disabled={appleBusy || !anisetteTrusted} onClick={() => void signInWithApple()}>{appleBusy ? "Waiting for Apple…" : "Sign in with Apple Account"}<ChevronRight size={15} /></button></div>
      </>}
    </section>
    <details className="form-card advanced-signing-files">
      <summary><span><span className="eyebrow">ADVANCED FALLBACK</span><strong>Import existing signing files</strong><small>Use an Apple Development .p12 and a matching device profile.</small></span><ChevronRight size={17} /></summary>
      <FileChoice label="Apple Development identity" detail="Encrypted .p12 or .pfx" value={p12Path} action={chooseP12} />
      <FileChoice label="Provisioning profile" detail="Must include this device’s UDID and matching App ID" value={profilePath} action={chooseProfile} />
      <label className="field-label" htmlFor="p12-password">P12 password</label>
      <input id="p12-password" type="password" autoComplete="new-password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Used locally to open the identity" />
      <div className="form-footnote"><LockKeyhole size={14} /><span>The encrypted P12 and profile are protected by Windows DPAPI. The password is kept in Windows Credential Manager and sent to the signer through a private stdin pipe, never in process arguments or logs.</span></div>
      <div className="form-actions"><button className="secondary-button" onClick={() => { setPassword(""); setP12Path(""); setProfilePath(""); }}>Clear fields</button><button className="primary-button" onClick={() => void save()} disabled={busy}>{busy ? "Saving…" : "Save signing identity"}<ChevronRight size={15} /></button></div>
      {snapshot?.signing.configured && <button className="danger-text-button remove-identity" onClick={() => void remove()}>Remove saved identity</button>}
    </details>
    <section className="form-card diagnostics-card">
      <div className="section-title compact"><div><div className="eyebrow">PHYSICAL DEVICE READINESS</div><h2>Device diagnostics</h2></div><button className="secondary-button small" onClick={onDiagnostics} disabled={diagnosing}><RefreshCw size={13} />{diagnosing ? "Checking…" : "Run Diagnostics"}</button></div>
      <p className="section-description">Checks the Windows Apple service, device bridge, USB/trust state, signing material, provisioning, and DreyzeStore pairing. Unknown means the connected device service does not expose that fact.</p>
      {readiness ? <>
        <div className="readiness-grid">
          <ReadinessRow title="Apple Mobile Device Service" check={readiness.appleMobileDeviceService} />
          <ReadinessRow title="USB connection" check={readiness.usbConnection} />
          <ReadinessRow title="Trust" check={readiness.trust} />
          <ReadinessRow title="Developer Mode" check={readiness.developerMode} />
          <ReadinessRow title="pymobiledevice3" check={readiness.pymobiledevice3} />
          <ReadinessRow title="Signing identity" check={readiness.signingIdentity} />
          <ReadinessRow title="Provisioning" check={readiness.provisioning} />
          <ReadinessRow title="DreyzeStore pairing" check={readiness.dreyzePairing} />
        </div>
        <div className="diagnostic-timestamp">Last checked {formatDate(readiness.runAt)}</div>
      </> : <div className="diagnostic-empty">Run diagnostics to check the current Windows PC and paired iPhone.</div>}
    </section>
    <section className="form-card test-install-card">
      <div className="section-title compact"><div><div className="eyebrow">REAL DEVICE TEST</div><h2>{testInstallation ? "Test app confirmed" : "Test Installation"}</h2></div>{testInstallation && <StatusPill ok label="Inventory confirmed" />}</div>
      {testInstallation ? <>
        <p className="section-description"><strong>{testInstallation.bundleIdentifier}</strong> · {testInstallation.version} ({testInstallation.build}) · Installed {formatDate(testInstallation.installedAt)}</p>
        <div className="signing-facts"><span><strong>Team</strong>{testInstallation.teamIdentifier ?? "Not reported"}</span><span><strong>Certificate</strong>{testInstallation.certificateExpiresAt ? expirySummary(testInstallation.certificateExpiresAt) : "Not reported"}</span><span><strong>Profile</strong>{testInstallation.provisioningExpiresAt ? expirySummary(testInstallation.provisioningExpiresAt) : "Not reported"}</span></div>
        <div className="form-actions"><button className="danger-text-button" onClick={onRemoveTestInstall}>Uninstall test app</button></div>
      </> : <>
        <p className="section-description">Choose a test IPA you authored or are authorized to install. The Companion accepts only <code>org.dreyzestore.test.*</code> bundle IDs, recalculates its SHA-256, validates the archive, signs locally, installs over USB, then checks bundle ID/version/build in device inventory. No IPA is included in the repository.</p>
        <div className="form-actions"><button className="primary-button" onClick={onTestInstall} disabled={testingInstall}>{testingInstall ? "Working…" : "Choose Test IPA"}<ChevronRight size={15} /></button></div>
      </>}
    </section>
    <div className="limitations-card"><div className="limitations-title"><AlertTriangle size={16} /><strong>Signing limits</strong></div><ul><li>Windows provisioning uses an unofficial reverse-engineered protocol and is not supported by Apple. A mock/test build cannot establish that Apple will accept a real account, team, certificate, profile, or installation. The Companion never promises permanent signing.</li><li>Personal Team limits and profile lifetimes are controlled by Apple and can change. Use the expiration values returned from a real certificate/profile when available; this build does not yet expose per-app profile expiry for its automatic path.</li><li>Developer Mode must be enabled by the iPhone owner. Current Windows discovery cannot report it reliably, so diagnostics may show Unknown.</li><li>Automatic signing fails closed for extensions, universal binaries, DER entitlements, and capabilities outside its narrow allowlist. Apple/device checks remain authoritative.</li><li>Signing out removes local Apple session data; it does not revoke certificates or remove installed apps. Certificate private key material stays in the local Windows credential store.</li></ul></div>
  </div>;
}

function ReadinessRow({ title, check }: { title: string; check: ReadinessCheck }) {
  const label = check.status === "pass" ? "PASS" : check.status === "fail" ? "FAIL" : "UNKNOWN";
  return <div className="readiness-row"><div className={`readiness-state ${check.status}`} aria-label={label}>{label}</div><div><strong>{title}</strong><span>{check.details}</span></div></div>;
}

function expirySummary(value: string) {
  const remaining = new Date(value).getTime() - Date.now();
  if (!Number.isFinite(remaining)) return "Not reported";
  if (remaining <= 0) return `Expired ${formatDate(value)}`;
  const days = Math.ceil(remaining / 86_400_000);
  return `Expires in ${days} ${days === 1 ? "day" : "days"} · ${formatDate(value)}`;
}

function StatusPill({ ok, label, neutral = false }: { ok: boolean; label: string; neutral?: boolean }) {
  return <span className={`status-pill ${ok ? "ok" : neutral ? "neutral" : "pending"}`}><i />{label}</span>;
}

function CheckCard({ icon, title, description, state, action }: { icon: ReactNode; title: string; description: string; state: "complete" | "pending"; action?: () => void }) {
  return <div className="check-card"><div className={`check-icon ${state}`}>{icon}</div><div className="check-copy"><strong>{title}</strong><span>{description}</span>{action && <button className="inline-link" onClick={action}>Configure <ChevronRight size={13} /></button>}</div><div className={`check-mark ${state}`}>{state === "complete" ? <Check size={13} /> : <span />}</div></div>;
}

function SetupStep({ number, icon, title, detail, state, last = false }: { number: string; icon: ReactNode; title: string; detail: string; state: "complete" | "pending" | "unknown"; last?: boolean }) {
  const complete = state === "complete";
  const unknown = state === "unknown";
  return <div className={`setup-step ${last ? "last" : ""}`}><div className={`step-number ${complete ? "done" : ""}`}>{complete ? <Check size={14} /> : number}</div><div className="step-icon">{icon}</div><div className="step-copy"><strong>{title}</strong><span>{detail}</span></div><StatusPill ok={complete} neutral={unknown} label={complete ? "Complete" : unknown ? "Not reported" : "Pending"} /></div>;
}

function FileChoice({ label, detail, value, action }: { label: string; detail: string; value: string; action: () => void }) {
  return <div className="file-choice"><div className="file-choice-icon"><FileKey2 size={16} /></div><div className="file-choice-copy"><strong>{label}</strong><span>{value || detail}</span></div><button className="secondary-button small" onClick={() => void action()}>{value ? "Change" : "Choose file"}</button></div>;
}
