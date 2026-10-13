import { useCallback, useEffect, useRef, useState } from "react";

type Permission = { configured: boolean; state: "active" | "standby" | "unavailable"; revision: number; leaseSeconds: number };
export function validPermission(value: unknown): value is Permission {
  if (!value || typeof value !== "object") return false;
  const p = value as Permission;
  return typeof p.configured === "boolean" && ["active", "standby", "unavailable"].includes(p.state) &&
    Number.isSafeInteger(p.revision) && p.revision >= 0 && Number.isFinite(p.leaseSeconds) && p.leaseSeconds >= 0 && p.leaseSeconds <= 60;
}
export function useWorkSwitch(enabled: boolean) {
  const [permission, setPermission] = useState<Permission | null>(null);
  const lease = useRef({ wall: 0, monotonic: 0, active: false });
  const allowed = useCallback(() => enabled && lease.current.active && Date.now() < lease.current.wall && performance.now() < lease.current.monotonic, [enabled]);
  useEffect(() => {
    lease.current = { wall: 0, monotonic: 0, active: false };
    setPermission(null);
    if (!enabled) return;
    let stopped = false;
    let inFlight = false;
    const abort = new AbortController();
    const check = async () => {
      if (stopped || inFlight || document.visibilityState === "hidden") return;
      inFlight = true;
      const started = performance.now();
      try {
        const response = await fetch("/api/work-state", { cache: "no-store", signal: AbortSignal.any([abort.signal, AbortSignal.timeout(8000)]) });
        const next: unknown = await response.json();
        if (!response.ok || !validPermission(next)) throw new Error("Invalid work permission");
        if (stopped) return;
        const remaining = Math.max(0, next.leaseSeconds * 1000 - (performance.now() - started));
        lease.current = { wall: Date.now() + remaining, monotonic: performance.now() + remaining, active: next.state === "active" };
        setPermission(next);
      } catch {
        if (!stopped) {
          lease.current = { wall: 0, monotonic: 0, active: false };
          setPermission({ configured: true, state: "unavailable", revision: 0, leaseSeconds: 0 });
        }
      } finally { inFlight = false; }
    };
    void check();
    const timer = window.setInterval(() => void check(), 30_000);
    document.addEventListener("visibilitychange", check);
    window.addEventListener("online", check);
    return () => { stopped = true; abort.abort(); window.clearInterval(timer); document.removeEventListener("visibilitychange", check); window.removeEventListener("online", check); };
  }, [enabled]);
  return {
    allowed,
    // Stable between control reads; a state/revision transition wakes consumers immediately.
    change: permission ? `${permission.state}:${permission.revision}` : "pending",
    label: !enabled || permission?.configured === false ? null : permission?.state === "active" ? "Switchr: On" : permission?.state === "standby" ? "Switchr: Off" : "Switchr: Pending",
  };
}
