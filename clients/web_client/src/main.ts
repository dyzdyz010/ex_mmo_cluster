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

function main(): void {
  bootstrap({
    canvas: requireCanvas(),
    hud: requireHud(),
  });
}

main();
