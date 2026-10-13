import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const script = "scripts/next-macos-version.sh";

describe("automatic macOS release versioning", () => {
  it("bumps the source patch when the public feed is at the source version", () => {
    expect(execFileSync(script, ["0.1.4", "0.1.4"], { encoding: "utf8" }).trim()).toBe("0.1.5");
  });

  it("continues after a newer public version if source metadata is behind", () => {
    expect(execFileSync(script, ["0.1.4", "0.1.5"], { encoding: "utf8" }).trim()).toBe("0.1.6");
  });

  it("preserves an intentionally higher source version", () => {
    expect(execFileSync(script, ["0.2.0", "0.1.5"], { encoding: "utf8" }).trim()).toBe("0.2.0");
  });

  it("advances beyond private builds that are ahead of the public feed", () => {
    expect(execFileSync(script, ["0.1.12", "0.1.12", "0.1.17"], { encoding: "utf8" }).trim()).toBe("0.1.18");
    expect(execFileSync(script, ["0.1.17", "0.1.12", "0.1.17"], { encoding: "utf8" }).trim()).toBe("0.1.18");
    expect(execFileSync(script, ["0.1.18", "0.1.12", "0.1.17"], { encoding: "utf8" }).trim()).toBe("0.1.18");
    expect(execFileSync(script, ["0.1.18", "0.1.20", "0.1.17"], { encoding: "utf8" }).trim()).toBe("0.1.21");
    expect(execFileSync(script, ["0.1.12", "", "0.1.17"], { encoding: "utf8" }).trim()).toBe("0.1.18");
  });

  it("rejects a malformed private version floor", () => {
    expect(spawnSync(script, ["0.1.18", "0.1.12", "invalid"]).status).toBe(64);
  });
  it("rejects reuse of a distributed release before packaging or signing", () => {
    const result = spawnSync('/bin/bash', ['scripts/release-macos-update.sh', '0.1.17'], { encoding: 'utf8' });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('exceed previously distributed builds');
  });
});

describe("private macOS packaging", () => {
  it("handles an omitted signing keychain in macOS Bash with nounset enabled", () => {
    if (process.platform !== "darwin") return;
    const fixture = mkdtempSync(join(tmpdir(), "watchr-signing-test-"));
    try {
      writeFileSync(join(fixture, "security"), "#!/bin/sh\necho '0 valid identities found'\n", { mode: 0o700 });
      const env = { ...process.env, PATH: `${fixture}:/usr/bin:/bin` };
      for (const key of ["STATUS_WATCHR_KEYCHAIN", "STATUS_WATCHR_RCODESIGN", "STATUS_WATCHR_CODESIGN_P12", "STATUS_WATCHR_CODESIGN_PASSWORD_FILE", "STATUS_WATCHR_CODESIGN_IDENTITY"]) delete env[key];
      const result = spawnSync("/bin/bash", ["scripts/build-macos-app.sh", join(fixture, "output")], { env, encoding: "utf8" });
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("Code Signing identity not found: Status Watchr Local Code Signing");
      expect(result.stderr).not.toContain("unbound variable");
    } finally {
      rmSync(fixture, { recursive: true, force: true });
    }
  });
});
