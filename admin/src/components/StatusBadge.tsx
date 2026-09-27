type StatusBadgeProps = {
  state: "checking" | "connected" | "unavailable";
};

const labels: Record<StatusBadgeProps["state"], string> = {
  checking: "Checking",
  connected: "Connected",
  unavailable: "Unavailable",
};

export function StatusBadge({ state }: StatusBadgeProps) {
  return (
    <span className={`status-badge status-${state}`} aria-live="polite">
      <span className="status-dot" aria-hidden="true" />
      {labels[state]}
    </span>
  );
}
