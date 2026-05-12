import { describe, expect, it } from "vitest";
import indexHtml from "../../../index.html?raw";

describe("HUD shell layout", () => {
  it("keeps the fixed HUD inside narrow mobile viewports", () => {
    const hudRule = indexHtml.match(/#hud\s*\{[^}]*\}/s)?.[0] ?? "";

    expect(hudRule).toContain("box-sizing: border-box");
  });

  it("makes the HUD readable and scrollable on touch-sized screens", () => {
    const mobileRules = indexHtml.slice(indexHtml.indexOf("@media (max-width: 480px)"));

    expect(mobileRules).toContain("#hud");
    expect(mobileRules).toContain("env(safe-area-inset-top)");
    expect(mobileRules).toContain("max-height:");
    expect(mobileRules).toContain("overflow-y: auto");
    expect(mobileRules).toContain("white-space: pre-wrap");
    expect(mobileRules).toContain("overflow-wrap: anywhere");
    expect(mobileRules).toContain("pointer-events: auto");
    expect(mobileRules).toContain("touch-action: pan-y");
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
