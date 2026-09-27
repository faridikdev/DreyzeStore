import { useState, type FormEvent } from "react";
import { apiURL, setCsrfToken, type AdminSession } from "../api/admin.js";

export function LoginPage({ onSignedIn }: { onSignedIn: (session: AdminSession) => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const response = await fetch(apiURL("/api/v1/admin/auth/login"), {
        method: "POST",
        credentials: "include",
        cache: "no-store",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, password }),
      });
      const payload = await response.json() as { data?: AdminSession; error?: { message?: string } };
      if (!response.ok || !payload.data) throw new Error(payload.error?.message ?? "Sign-in was not accepted.");
      setCsrfToken(payload.data.csrfToken);
      onSignedIn(payload.data);
      setPassword("");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "The sign-in request failed.");
      setPassword("");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="login-screen">
      <section className="login-card" aria-labelledby="login-title">
        <div className="brand-lockup"><span className="wordmark-mark">D</span><span>DreyzeStore <i>Admin</i></span></div>
        <p className="eyebrow">STORE OPERATIONS</p>
        <h1 id="login-title">Sign in</h1>
        <p className="muted">Use the administrator account configured for this store.</p>
        <form onSubmit={(event) => void submit(event)} className="form-stack">
          <label>Email<input type="email" autoComplete="username" value={email} onChange={(event) => setEmail(event.target.value)} required maxLength={254} /></label>
          <label>Password<input type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} required maxLength={256} /></label>
          {error && <p className="notice error" role="alert">{error}</p>}
          <button className="primary" type="submit" disabled={busy}>{busy ? "Signing in…" : "Continue"}</button>
        </form>
        <p className="login-footnote">Sessions are short-lived and held in a secure, HttpOnly cookie.</p>
      </section>
    </main>
  );
}
