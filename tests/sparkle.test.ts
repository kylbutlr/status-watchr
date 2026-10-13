import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

function plistValue(contents: string, key: string) {
  return contents.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`, "u"))?.[1];
}

function expectedBuild(version: string) {
  const [major, minor, patch] = version.split(".").map(Number);
  return String((major * 1_000_000) + (minor * 1_000) + patch);
}

describe("Sparkle release metadata", () => {
  it("keeps the base app build number comparable with release builds", () => {
    const plist = readFileSync("apps/macos/Resources/Info.plist", "utf8");
    const version = plistValue(plist, "CFBundleShortVersionString");
    const build = plistValue(plist, "CFBundleVersion");

    expect(version).toBeTruthy();
    expect(build).toBe(expectedBuild(version ?? "0.0.0"));
  });

  it("signs CI releases without modifying macOS keychains or trust settings", () => {
    const workflow = readFileSync(".github/workflows/macos-release.yml", "utf8");
    const buildScript = readFileSync("scripts/build-macos-app.sh", "utf8");

    expect(workflow).toContain("rcodesign_version=\"0.29.0\"");
    expect(workflow).toContain("d98372d5524226ccf9dc0eda03d4e4f5826182dabb2fc3f2bd303ed9113a748d");
    expect(workflow).toContain("echo \"STATUS_WATCHR_RCODESIGN=$rcodesign_path\" >> \"$GITHUB_ENV\"");
    expect(workflow).toContain("echo \"STATUS_WATCHR_CODESIGN_P12=$certificate_path\" >> \"$GITHUB_ENV\"");
    expect(workflow).toContain("echo \"STATUS_WATCHR_CODESIGN_PASSWORD_FILE=$password_path\" >> \"$GITHUB_ENV\"");
    expect(workflow).not.toContain("security ");
    expect(buildScript).toContain("--p12-file \"$signing_p12\"");
    expect(buildScript).toContain("--p12-password-file \"$signing_password_file\"");
    expect(buildScript).toContain("signature_verifies: true");
  });
});
