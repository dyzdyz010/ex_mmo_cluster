import { bootstrap } from "./app/bootstrap";

function requireHud(): HTMLDivElement {
  const hud = document.getElementById("hud");
  if (!(hud instanceof HTMLDivElement)) {
    throw new Error("#hud element missing or wrong type");
  }
  return hud;
}

function requireCanvas(): HTMLCanvasElement {
  const canvas = document.getElementById("app");
  if (!(canvas instanceof HTMLCanvasElement)) {
    throw new Error("#app canvas missing");
  }
  return canvas;
}

function requireHotbarDock(): HTMLDivElement {
  const dock = document.getElementById("hotbar-dock");
  if (!(dock instanceof HTMLDivElement)) {
    throw new Error("#hotbar-dock element missing or wrong type");
  }
  return dock;
}

function requireVoxelPanel(): HTMLDivElement {
  const panel = document.getElementById("voxel-panel");
  if (!(panel instanceof HTMLDivElement)) {
    throw new Error("#voxel-panel element missing or wrong type");
  }
  return panel;
}

async function main(): Promise<void> {
  await bootstrap({
    canvas: requireCanvas(),
    hud: requireHud(),
    hotbarDock: requireHotbarDock(),
    voxelPanel: requireVoxelPanel(),
  });
}

main().catch((error: unknown) => {
  console.error("[web-client] bootstrap failed", error);
});
