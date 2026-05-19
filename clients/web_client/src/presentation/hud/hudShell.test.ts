import { describe, expect, it } from "vitest";
import indexHtml from "../../../index.html?raw";

describe("HUD shell layout", () => {
  it("keeps the fixed HUD inside narrow mobile viewports", () => {
    const hudRule = indexHtml.match(/#hud\s*\{[^}]*\}/s)?.[0] ?? "";

    expect(hudRule).toContain("box-sizing: border-box");
  });

  it("hides the developer HUD and voxel debug panel under html.is-touch", () => {
    expect(indexHtml).toMatch(/html\.is-touch\s+#hud[\s\S]*?display:\s*none/);
    expect(indexHtml).toMatch(/html\.is-touch\s+#voxel-panel[\s\S]*?display:\s*none/);
  });

  it("sizes the canvas with dynamic viewport units to avoid iOS Safari 100vh stretch", () => {
    const appRule = indexHtml.match(/#app\s*\{[^}]*\}/s)?.[0] ?? "";
    expect(appRule).toMatch(/width:\s*100dvw/);
    expect(appRule).toMatch(/height:\s*100dvh/);
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

  it("provides touch zones, sticks, action buttons and mobile operation buttons inside touch-controls", () => {
    expect(indexHtml).toMatch(/\.touch-zone--left\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-zone--right\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-stick--left\s*\{/);
    expect(indexHtml).toMatch(/\.touch-stick--right\s*\{/);
    expect(indexHtml).toMatch(/\.touch-buttons\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-ops\s*\{[^}]*pointer-events:\s*auto/s);
    expect(indexHtml).toMatch(/\.touch-btn--jump\s*\{/);
    expect(indexHtml).toMatch(/\.touch-btn--break\s*\{/);
    expect(indexHtml).toMatch(/\.touch-btn--place\s*\{/);
    expect(indexHtml).toContain('aria-label="Toggle field overlay"');
    expect(indexHtml).toContain('aria-label="Heat aimed block"');
    expect(indexHtml).toContain('aria-label="Conduct aimed path"');
    expect(indexHtml).toContain('aria-label="Subscribe aimed chunk"');
  });

  it("keeps the touch hotbar in one compact row so it does not collide with right thumb buttons", () => {
    const touchDockRule = indexHtml.match(/html\.is-touch\s+#hotbar-dock\s*\{[^}]*\}/s)?.[0] ?? "";
    const touchSlotsRule =
      indexHtml.match(/html\.is-touch\s+\.hotbar-slots\s*\{[^}]*\}/s)?.[0] ?? "";

    expect(touchDockRule).toContain("calc(100vw - 284px)");
    expect(touchSlotsRule).toMatch(/grid-template-columns:\s*repeat\(9,/);
  });

  it("hides touch sticks/buttons/operations and shows orientation warning in portrait", () => {
    const portraitBlock = indexHtml.match(/@media \(orientation: portrait\)[^@]*/s)?.[0] ?? "";
    expect(portraitBlock).toMatch(/\.orientation-warning\s*\{[^}]*display:\s*flex/s);
    expect(portraitBlock).toMatch(/\.touch-zone[^{]*\{[^}]*display:\s*none/s);
    expect(portraitBlock).toMatch(/\.touch-buttons,[\s\S]*?\.touch-ops\s*\{[^}]*display:\s*none/s);
    expect(portraitBlock).toMatch(/#hotbar-dock\s*\{[^}]*display:\s*none/s);
  });
});
