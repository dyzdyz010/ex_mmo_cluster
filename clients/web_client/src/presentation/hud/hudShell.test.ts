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

  it("declares #touch-controls hidden by default and shown only under html.is-touch", () => {
    const touchRule = indexHtml.match(/#touch-controls\s*\{[^}]*\}/s)?.[0] ?? "";
    expect(touchRule).toContain("display: none");

    const enableRule = indexHtml.match(/html\.is-touch\s+#touch-controls\s*\{[^}]*\}/s)?.[0] ?? "";
    expect(enableRule).toContain("display: block");
  });

  it("provides touch zones, sticks and action buttons inside touch-controls", () => {
    expect(indexHtml).toMatch(/\.touch-zone--left\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-zone--right\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-stick--left\s*\{/);
    expect(indexHtml).toMatch(/\.touch-stick--right\s*\{/);
    expect(indexHtml).toMatch(/\.touch-buttons\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-btn--jump\s*\{/);
    expect(indexHtml).toMatch(/\.touch-btn--break\s*\{/);
    expect(indexHtml).toMatch(/\.touch-btn--place\s*\{/);
  });

  it("hides touch sticks/buttons and shows orientation warning in portrait", () => {
    const portraitBlock = indexHtml.match(/@media \(orientation: portrait\)[^@]*/s)?.[0] ?? "";
    expect(portraitBlock).toMatch(/\.orientation-warning\s*\{[^}]*display:\s*flex/s);
    expect(portraitBlock).toMatch(/\.touch-zone[^{]*\{[^}]*display:\s*none/s);
    expect(portraitBlock).toMatch(/\.touch-buttons\s*\{[^}]*display:\s*none/s);
  });
});
