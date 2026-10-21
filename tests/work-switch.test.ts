import { afterEach, describe, expect, it, vi } from "vitest";
const database = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock("@neondatabase/serverless", () => ({ neon: database.open }));
vi.mock('@netlify/blobs', () => import('./blob-fixture'));
import handler from "../netlify/functions/api.mts";
import maintenance from "../netlify/functions/notification-retry.mts";
import retention from '../netlify/functions/retention-scheduled.mts';
import { workPermission } from "../netlify/functions/lib/work-switch";
import { validPermission } from "../src/work-switch";

afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.clearAllMocks(); });
function configured(state = "standby", leaseSeconds = 60) {
  vi.stubEnv("APP_SWITCHR_URL", "https://switchr.test/api/work-state");
  vi.stubEnv("APP_SWITCHR_READER_TOKEN", "reader");
  const fetch = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) => Response.json({ state, revision: 2, leaseSeconds }));
  vi.stubGlobal("fetch", fetch);
  return fetch;
}
describe("App Switchr prevents hosted work before Neon", () => {
  it("keeps the unconfigured deployment active and fails closed for partial setup", async () => {
    vi.stubEnv("APP_SWITCHR_URL", ""); vi.stubEnv("APP_SWITCHR_READER_TOKEN", "");
    expect((await workPermission()).configured).toBe(false);
    vi.stubEnv("APP_SWITCHR_URL", "https://switchr.test/api/work-state");
    expect((await workPermission()).state).toBe("unavailable");
  });
  it("requires authentication even for the control read", async () => {
    const fetch = configured();
    vi.stubEnv("WATCHR_INGEST_TOKEN", "ingest");
    expect((await handler(new Request("https://watchr.test/api/work-state"))).status).toBe(401);
    expect(fetch).not.toHaveBeenCalled();
    const response = await handler(new Request("https://watchr.test/api/work-state", { headers: { authorization: "Bearer ingest" } }));
    expect((await response.json()).state).toBe("standby");
    expect(database.open).not.toHaveBeenCalled();
  });
  it.each(["standby", "unavailable"])("does not acknowledge queued uploads or touch Neon while %s", async (state) => {
    configured(state);
    vi.stubEnv("DATABASE_URL", "postgres://unused"); vi.stubEnv("WATCHR_INGEST_TOKEN", "ingest");
    for (const path of ["events", "collector"]) {
      const response = await handler(new Request(`https://watchr.test/api/${path}`, { method: "POST", headers: { authorization: "Bearer ingest" }, body: "{}" }));
      expect(response.status).toBe(503);
      expect(response.headers.get("retry-after")).toBe("30");
    }
    await maintenance();
    await retention();
    expect(database.open).not.toHaveBeenCalled();
  });
  it("resumes maintenance after On", async () => {
    configured("active"); vi.stubEnv("DATABASE_URL", "postgres://unused");
    database.open.mockReturnValue(vi.fn(async () => []));
    await retention();
    expect(database.open).toHaveBeenCalledOnce();
  });
  it("fails closed for expired or malformed permission and disallows redirects", async () => {
    const fetch = configured("active", 0);
    vi.stubEnv("WATCHR_INGEST_TOKEN", "ingest");
    expect((await handler(new Request("https://watchr.test/api/events", { method: "POST", headers: { authorization: "Bearer ingest" } }))).status).toBe(503);
    expect(fetch.mock.calls[0][1]).toMatchObject({ redirect: "error" });
    for (const leaseSeconds of [-1, 61, Infinity]) {
      configured("active", leaseSeconds);
      expect((await workPermission()).state).toBe("unavailable");
      expect(validPermission({ configured: true, state: "active", revision: 1, leaseSeconds })).toBe(false);
    }
  });
});
