import { Vector3 } from "three";
import { describe, expect, it } from "vitest";
import { createSkyAtmosphere } from "./skyAtmosphere";

describe("createSkyAtmosphere", () => {
  it("creates a sky group with sun, moon, and dynamic lighting", () => {
    const sky = createSkyAtmosphere();
    const sun = sky.group.getObjectByName("voxel-sun-disc");
    const initialSunY = sun?.position.y;

    sky.update(30, new Vector3(10, 20, 30));

    expect(sky.group.name).toBe("voxel-sky-atmosphere");
    expect(sky.group.position).toMatchObject({ x: 10, y: 20, z: 30 });
    expect(sun).toBeDefined();
    expect(sky.group.getObjectByName("voxel-moon-disc")).toBeDefined();
    expect(sky.sunLight.intensity + sky.moonLight.intensity).toBeGreaterThan(0);
    expect(sun?.position.y).not.toBe(initialSunY);

    sky.dispose();
  });
});
