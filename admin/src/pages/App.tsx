import { useCallback, useEffect, useState } from "react";
import { checkApiHealth } from "../api/health.js";
import { StatusBadge } from "../components/StatusBadge.js";

type ConnectionState =
  | { kind: "checking" }
  | { kind: "connected"; database: string }
  | { kind: "unavailable"; message: string };

const apiBaseURL = import.meta.env.VITE_API_BASE_URL;

export function App() {
  const [connection, setConnection] = useState<ConnectionState>({ kind: "checking" });

  const refreshConnection = useCallback(async () => {
    setConnection({ kind: "checking" });
    try {
      const health = await checkApiHealth(apiBaseURL);
      setConnection({ kind: "connected", database: health.database });
    } catch (error) {
      setConnection({
        kind: "unavailable",
        message: error instanceof Error ? error.message : "The API could not be reached.",
      });
    }
  }, []);

  useEffect(() => {
    void refreshConnection();
  }, [refreshConnection]);

  return (
    <main className="workspace">
      <header className="topbar">
        <a className="wordmark" href="/" aria-label="DreyzeStore Admin home">
          <span className="wordmark-mark" aria-hidden="true">D</span>
          <span>DreyzeStore</span>
          <span className="wordmark-divider" />
          <span className="wordmark-caption">Admin</span>
        </a>
        <span className="environment-label">FOUNDATION</span>
      </header>

      <section className="page-heading" aria-labelledby="page-title">
        <p className="eyebrow">STORE OPERATIONS</p>
        <h1 id="page-title">Workspace</h1>
        <p className="lede">Check the API here; catalog workflows arrive in later phases.</p>
      </section>

      <section className="connection-card" aria-labelledby="connection-title">
        <div className="card-heading">
          <div>
            <p className="eyebrow">SERVICE STATUS</p>
            <h2 id="connection-title">API connection</h2>
          </div>
          <StatusBadge state={connection.kind} />
        </div>
        <div className="card-body">
          {connection.kind === "connected" ? (
            <p>The API is responding and the metadata database is ready.</p>
          ) : connection.kind === "checking" ? (
            <p role="status">Checking the configured API…</p>
          ) : (
            <p role="status">{connection.message}</p>
          )}
          <div className="connection-details">
            <span>Endpoint</span>
            <code>{apiBaseURL || "Not configured"}</code>
            {connection.kind === "connected" && (
              <>
                <span>Metadata</span>
                <code>{connection.database}</code>
              </>
            )}
          </div>
        </div>
        <div className="card-footer">
          <span>Admin workflows are introduced in a later phase.</span>
          <button type="button" onClick={() => void refreshConnection()} disabled={connection.kind === "checking"}>
            Check connection
          </button>
        </div>
      </section>

      <footer className="page-footer">
        <span>DreyzeStore Admin</span>
        <span>Local foundation build</span>
      </footer>
    </main>
  );
}
