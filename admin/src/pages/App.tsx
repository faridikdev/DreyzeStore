import { useEffect, useState } from "react";
import { apiRequest, setCsrfToken, type AdminSession } from "../api/admin.js";
import { LoginPage } from "./LoginPage.js";
import { AdminWorkspace } from "./AdminWorkspace.js";

type AppState = { kind: "checking" } | { kind: "signedOut" } | { kind: "signedIn"; session: AdminSession };

export function App() {
  const [state, setState] = useState<AppState>({ kind: "checking" });

  useEffect(() => {
    let active = true;
    void apiRequest<AdminSession>("/api/v1/admin/auth/session")
      .then((session) => {
        if (active) { setCsrfToken(session.csrfToken); setState({ kind: "signedIn", session }); }
      })
      .catch(() => { if (active) setState({ kind: "signedOut" }); });
    return () => { active = false; };
  }, []);

  async function signOut() {
    try { await apiRequest("/api/v1/admin/auth/logout", { method: "POST", body: "{}" }); }
    finally { setCsrfToken(""); setState({ kind: "signedOut" }); }
  }

  if (state.kind === "checking") return <main className="login-screen"><p role="status" className="muted">Checking your admin session…</p></main>;
  if (state.kind === "signedOut") return <LoginPage onSignedIn={(session) => setState({ kind: "signedIn", session })} />;
  return <AdminWorkspace key={state.session.id} session={state.session} onSignOut={() => void signOut()} />;
}
