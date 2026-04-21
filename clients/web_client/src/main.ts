import { AppRuntime } from "./runtime/appRuntime";

function mountHud(): HTMLDivElement {
  const hud = document.getElementById("hud");
  if (!(hud instanceof HTMLDivElement)) {
    throw new Error("#hud element missing or wrong type");
  }
  return hud;
}

function main(): void {
  const canvas = document.getElementById("app");
  if (!(canvas instanceof HTMLCanvasElement)) {
    throw new Error("#app canvas missing");
  }

  const hud = mountHud();
  AppRuntime.boot(canvas, hud);
}

main();
