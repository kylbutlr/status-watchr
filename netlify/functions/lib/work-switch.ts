/** This check deliberately has no database dependency. */
export type WorkPermission = { configured: boolean; state: "active" | "standby" | "unavailable"; revision: number; leaseSeconds: number };
export async function workPermission(): Promise<WorkPermission> {
  const endpoint = process.env.APP_SWITCHR_URL;
  const token = process.env.APP_SWITCHR_READER_TOKEN;
  if (!endpoint && !token) return { configured: false, state: "active", revision: 0, leaseSeconds: 60 };
  const unavailable: WorkPermission = { configured: true, state: "unavailable", revision: 0, leaseSeconds: 0 };
  if (!endpoint || !token) return unavailable;
  try {
    const url = new URL(endpoint);
    if (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))) return unavailable;
    const started = performance.now();
    const response = await fetch(url, { headers: { authorization: `Bearer ${token}` }, cache: "no-store", redirect: "error", signal: AbortSignal.timeout(5_000) });
    if (!response.ok) return unavailable;
    const data = await response.json() as Record<string, unknown>;
    if (!["active", "standby"].includes(String(data.state)) || (!Number.isSafeInteger(data.revision) || Number(data.revision) < 0)
      || typeof data.leaseSeconds !== "number" || !Number.isFinite(data.leaseSeconds) || data.leaseSeconds < 0 || data.leaseSeconds > 60) return unavailable;
    return { configured: true, state: data.state as "active" | "standby", revision: data.revision as number,
      leaseSeconds: Math.max(0, data.leaseSeconds - (performance.now() - started) / 1_000) };
  } catch { return unavailable; }
}
export async function automaticWorkAllowed(): Promise<boolean> {
  const permission = await workPermission();
  return permission.state === "active" && permission.leaseSeconds > 0;
}
