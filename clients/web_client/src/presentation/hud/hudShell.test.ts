import { describe, expect, it } from "vitest";
import indexHtml from "../../../index.html?raw";

describe("HUD shell layout", () => {
  it("keeps the fixed HUD inside narrow mobile viewports", () => {
    const hudRule = indexHtml.match(/#hud\s*\{[^}]*\}/s)?.[0] ?? "";

    expect(hudRule).toContain("box-sizing: border-box");
  });

  it("hides the developer HUD and voxel debug panel on touch-sized screens", () => {
    const mobileRules = indexHtml.slice(indexHtml.indexOf("@media (max-width: 480px)"));

    expect(mobileRules).toMatch(/#hud\s*\{[^}]*display:\s*none/);
    expect(mobileRules).toMatch(/#voxel-panel\s*\{[^}]*display:\s*none/);
  });

  it("mounts a fixed bottom hotbar dock shell", () => {
    const dockRule = indexHtml.match(/#hotbar-dock\s*\{[^}]*\}/s)?.[0] ?? "";

    expect(indexHtml).toContain('id="hotbar-dock"');
    expect(dockRule).toContain("position: fixed");
    expect(dockRule).toContain("bottom:");
    expect(dockRule).toContain("left: 50%");
    expect(dockRule).toContain("box-sizing: border-box");
  });
});
