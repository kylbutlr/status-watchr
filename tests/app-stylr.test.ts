import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("App Stylr consumer contract", () => {
  it("pins the v1.2.0 source dark contract and records local exceptions", () => {
    const manifest = JSON.parse(readFileSync("app-stylr.json", "utf8"));
    const styles = readFileSync("src/styles.css", "utf8");
    const exceptions = readFileSync("docs/app-stylr-exceptions.md", "utf8");

    expect(manifest).toEqual({
      name: "App Stylr",
      version: "1.2.0",
      sourceRevision: "b3ca31ea264d5dd233fd871ac167247f1c306985",
      release: "https://github.com/kylbutlr/app-stylr/tree/b3ca31ea264d5dd233fd871ac167247f1c306985",
      theme: "dark",
      exceptions: "docs/app-stylr-exceptions.md"
    });
    expect(styles).toContain("--canvas: var(--ui-canvas);");
    expect(styles).toContain("--accent: var(--ui-accent);");
    expect(exceptions).toContain("Existing local semantic aliases");
    expect(exceptions).toContain("Locally bundled Geist and Geist Mono");
  });
});
