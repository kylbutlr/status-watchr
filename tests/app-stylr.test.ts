import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("App Stylr consumer contract", () => {
  it("pins the v1.4.1 source dark contract and records local exceptions", () => {
    const manifest = JSON.parse(readFileSync("app-stylr.json", "utf8"));
    const styles = readFileSync("src/styles.css", "utf8");
    const exceptions = readFileSync("docs/app-stylr-exceptions.md", "utf8");

    expect(manifest).toEqual({
      name: "App Stylr",
      version: "1.4.1",
      sourceRevision: "6fbc524f07ed7aa7db9c8593bf8116b9440937bc",
      release: "https://github.com/kylbutlr/app-stylr/tree/v1.4.1",
      sourceTag: "v1.4.1",
      accent: "mint",
      surfaceTone: "normal",
      density: "comfortable",
      theme: "dark",
      exceptions: "docs/app-stylr-exceptions.md"
    });
    expect(styles).toContain("--canvas: var(--ui-canvas);");
    expect(styles).toContain("--accent: var(--ui-accent);");
    expect(exceptions).toContain("Existing local semantic aliases");
    expect(exceptions).toContain("Locally bundled Geist and Geist Mono");
  });
});
