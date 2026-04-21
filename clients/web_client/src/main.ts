import { createScene } from "./render/scene";
import { ChunkStorage } from "./voxel/storage/chunkStorage";
import { VoxelConstants } from "./voxel/core/constants";

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

  const { renderer, scene, camera, dispose } = createScene(canvas);
  const hud = mountHud();

  // W-A 阶段冒烟：仅确认类型和量化换算在浏览器里可用。
  const chunk = ChunkStorage.createEmpty({ x: 0, y: 0, z: 0 });
  const macroCount = chunk.data.macroHeaders.length;

  let frame = 0;
  const start = performance.now();
  const tick = () => {
    frame += 1;
    const elapsed = (performance.now() - start) / 1000;
    const fps = frame / Math.max(elapsed, 1e-3);

    hud.textContent = [
      `ex_mmo voxel web-client (W-A)`,
      `chunk 16^3 macros = ${macroCount}`,
      `MicroPerMacro = ${VoxelConstants.MicroPerMacro}`,
      `fps ≈ ${fps.toFixed(1)}`,
    ].join("\n");

    renderer.render(scene, camera);
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);

  window.addEventListener("beforeunload", dispose, { once: true });
}

main();
