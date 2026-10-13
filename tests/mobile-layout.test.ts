import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const styles = readFileSync("src/styles.css", "utf8");
const appSource = readFileSync("src/App.tsx", "utf8");
const notificationSource = readFileSync("src/Notifications.tsx", "utf8");
const apiSource = readFileSync("netlify/functions/api.mts", "utf8");

describe("mobile layout constraints", () => {
  it('shows list or detail on phones instead of stacking detail below every inactive item', () => {
    expect(styles).toMatch(/@media \(max-width: 850px\)[\s\S]*\.work-area:not\(\.mobile-details-open\) \.activity-panel, \.work-area\.mobile-details-open \.session-column \{ display: none; \}/);
    expect(appSource).toContain('Back to conversations');
    expect(appSource.indexOf('<NotificationOverview')).toBeLessThan(appSource.indexOf('<section className={`work-area'));
  });
  it("allows the work-area grid children to shrink to the viewport", () => {
    expect(styles).toMatch(/\.session-column,\s*\.activity-panel\s*\{[^}]*min-width:\s*0/);
    expect(styles).toMatch(/\.session-list\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/);
    expect(styles).toMatch(/\.session-card\s*\{[^}]*min-width:\s*0/);
    expect(styles).not.toMatch(/\.work-area\s*\{[^}]*minmax\(370px/);
  });

  it("loads activity in server-backed pages of ten while preserving global counts", () => {
    expect(apiSource).toContain("const sessionPageSize = 10");
    expect(apiSource).toContain("limit ${sessionPageSize + 1}");
    expect(appSource).toContain("liveSessionPageSize = 10");
    expect(appSource).toContain("Load ${nextSessionCount || liveSessionPageSize} more");
    expect(appSource).toContain("setLiveCounts({");
    expect(appSource).toContain("activeSessions.map");
  });

  it("keeps secondary collector controls collapsed on phones", () => {
    expect(notificationSource).toContain('aria-controls="dashboard-settings"');
    expect(notificationSource).toContain("hidden={panel !== 'settings'}");
    expect(styles).toContain('.quick-controls-panel[hidden] { display: none; }');
    expect(appSource).toContain('collectorControls={<>');
  });

  it("removes the decorative hero and leads with collector status", () => {
    expect(appSource).not.toContain("What needs you?");
    expect(appSource).not.toContain("A quiet view of the work happening across your agents.");
    expect(appSource).toContain('checkIn={<MacCheckIn');
    expect(notificationSource).toContain('className="quick-controls"');
    expect(styles).toContain('.compact-controls ~ .work-area { margin-top: 12px; }');
  });

  it("keeps phone monitoring read-only and explains the attention gap", () => {
    expect(appSource).toContain("Observation only");
    expect(appSource).toContain("Respond to questions and approvals on the Mac");
    expect(appSource).toContain("question detection remains unverified");
  });

  it("refreshes an on-demand dashboard when the browser regains focus", () => {
    expect(appSource).toContain('window.addEventListener("focus", runImmediately)');
    expect(appSource).toContain('window.removeEventListener("focus", runImmediately)');
  });
});
